---
date: 2026-10-11
updated: 2026-11-04
tags: [finding]
---

# per-Ractor GC で Ractor の使い捨てが高くつく（master 17aeb89200）

master の per-Ractor GC では、Ractor 1 つごとに次の処理が走る。

- objspace（専用ヒープ）の生成と、ヒープページ約 3 枚の確保
- 終了時の full GC（retire GC）
- その objspace を別の Ractor に統合する absorb

biryani はストリームごとに Ractor を使い捨てるので、これがリクエストごとのコストになる。
スループットは 4.0.5 の約 43% に落ち、最大 RSS は約 20 倍になった（[scenarios/ruby-master-vs-405](../scenarios/ruby-master-vs-405.md)）。
加えて、absorb の free page チェーン連結に **O(N²)** の箇所があり、終了時の後始末が数秒かかっていた。

## 詳細

### 1. Ractor ごとの固定コスト（uprobe で回数を計測）

`perf probe` で関数の呼び出し回数を数えた（master + absorb 修正、biryani `-c25 -m50 -n10000` の 1 回分）。

| 関数 | 回数 | Ractor あたり |
|---|---|---|
| [`rb_gc_impl_objspace_alloc`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L13350-L13360) | 10,055 | 1 |
| [`rb_gc_impl_objspace_retire_gc`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L8685-L8707) | 10,053 | 1 |
| [`objspace_absorb`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L9996-L10233) | 10,053 | 1 |
| `gc_start` | 10,200 | ≈ 1（ほぼすべて retire GC） |
| `heap_page_allocate_and_initialize` | 31,041 | ≈ 3 |
| `gc_sweep_page` | 407,699 | ≈ 40 |

10,000 リクエスト = 10,000 個の Stream Ractor（+ 接続ごとの Connection / recv_loop 各 25）。
retire GC は、終了するスレッドが自分の objspace に対して `GPR_FLAG_FULL_MARK | GPR_FLAG_IMMEDIATE_SWEEP` の GC を行うもの（[`ractor.c:755`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/ractor.c#L755) の `rb_gc_objspace_postmortem_self` 経由）。
deferred zombie を片付けた場合は 2 回目の GC も走る。

absorb 修正後の FlameGraph で上位に来るのは、この処理の中身である。

- `gc_sweep_plane` 14.4%
- `page_pool_acquire` 8.2%
- `gc_sweep_register_free_slot` 6.6%
- libc（memset など）11.8%

Ractor 生成時の空ヒープの確保・初期化と、終了時の sweep がほとんどを占める。

### 2. `objspace_absorb` の O(N²)

absorb 前の master の FlameGraph では、`objspace_absorb` の self が ruby プロセスの 58.5% を占めた。
`perf annotate` で見ると、そのサンプルの 99.6% が [`gc/default/default.c:10069`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L10066-L10072) の 1 行に集中していた。

```c
/* Append the free-page chain to the tail. */
if (sheap->free_pages) {
    struct heap_page **tail = &dheap->free_pages;
    while (*tail) tail = &(*tail)->free_next;   // ← dst の free page 連結リストを毎回末尾まで辿る
    *tail = sheap->free_pages;
```

absorb のたびに、吸収する側（dst）の `free_pages` 連結リストを末尾まで辿っている。
absorb するたびに dst のリストは src の分だけ伸びるので、N 回の absorb で O(N²) になる。
命令レベルでは 93% が `free_next` のロード 1 命令（ポインタチェイスのキャッシュミス）だった。この行は `85e3df9eaa`（2026-08-01、per-Ractor GC 本体）で入った。

absorb は次の 3 か所で起きる（[`gc.c:4693-4797`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc.c#L4693-L4797)）。

| 経路 | いつ | 吸収先 |
|------|------|-------|
| `rb_gc_objspace_absorb_into_current` | `Ractor#value` で join したとき | join した Ractor |
| `objspace_absorb_disowned_zombies` | join されないまま Ractor オブジェクトが回収されたとき（postponed job） | main Ractor |
| `rb_gc_objspace_absorb_all_zombies` | VM 終了時（[`ractor.c:1281`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/ractor.c#L1281)） | main Ractor |

biryani は Stream Ractor を `value` しないので、2 番目と 3 番目の経路で main に集まる。

**修正の実験**: dst のリストではなく src の（短い）リストを辿り、src のチェーンを dst の先頭に付け替える形に変えた。
sweep が free page を足すときも先頭に付け足している（`page->free_next = heap->free_pages`）ので、順序を変えても正しさは保たれると考えている。

| 指標 | master | master + 修正 | 4.0.5 |
|------|-------|--------------|-------|
| Ractor 20,000 個の逐次生成・join（マイクロベンチ） | 4.09 s | **1.52 s** | 1.19 s |
| biryani: プロセス全体の wall time | 9.15 s | **3.81 s** | 1.52 s |
| biryani: h2load のスループット | 約 3,400 req/s | 約 3,400 req/s（変化なし） | 約 8,000 req/s |

修正後は、マイクロベンチの所要時間が Ractor 数に対して線形になった（1,000 個あたり 0.07〜0.08 s で一定）。
biryani ではリクエスト処理中の absorb は少なく、ほとんどが終了時に起きているので、スループットは変わらなかった。

### 3. 終了した Ractor のメモリがグローバル GC まで返らない

マイクロベンチで、Ractor を 1 つ作っては `value` で回収し、RSS を記録した。

```
             4.0.5                         master 17aeb89200
  2,000 個   rss=11MB  global_gc=203       rss=145MB  global_gc=0
  8,000 個   rss=11MB  global_gc=803       rss=543MB  global_gc=0
 10,000 個   rss=11MB  global_gc=1003      rss=587MB  global_gc=1
 20,000 個   rss=11MB  global_gc=2003      rss=673MB  global_gc=2
```

- master では、Ractor 1 つあたり約 66 KB が残る。グローバル GC が 8,000〜10,000 個目あたりで初めて走るまで、RSS は線形に増え続ける
- absorb 修正を入れても RSS は変わらない（別の問題）
- biryani（`-n10000`）では最大 RSS が 2.2 GB になり、perf のバッファ（512 MB）を足すと 4 GB の VM で OOM になった
- 仮説（未検証）: biryani では main Ractor が `system("h2load")` でブロックしているため、main で実行される disowned zombie 吸収の postponed job が h2load の終了まで進まない。その間、zombie の objspace が溜まり続ける
- **2026-11-03（4.1.0-preview1 + biryani main `7359e96`）**: `load/server_c25_m50.rb`（`-n10000`）の最大 RSS は 4.1.0-preview1 で 2.20 GB、master `17aeb89200` で 2.20 GB、4.0.5 で 96 MB だった（biryani の更新では変わらない）。
  1 プロセスで 10,000 リクエストの h2load を続けて流す `load/bench_c.rb` は、2 回目の run の途中で anon-rss 3.6 GB に達し、**3 回中 3 回とも OOM killer に kill された**。`load/bench_m.rb` も途中から失敗した。
  1 回目の run のメモリが返りきらないまま 2 回目に入っている。4.1 を既定にした今、サーバーを使い回すスクリプトは 4 GB の VM では使えない
- 同じ条件（`-c50 -m100`）で、OOM ではなく `[BUG] cannot create a new page after major GC` で落ちることもある → [findings/gc-cannot-create-page-after-major-gc](gc-cannot-create-page-after-major-gc.md)
- **run を重ねたときの RSS**: 1 プロセスで `h2load -n5000 -c25 -m50` を 8 回続けて流し、各 run の後の RSS を測った。各 run の後に 3 秒待っても RSS は下がらなかった

  ```
  run                                   1      2      3      4      5      6      7      8
  4.1.0-pre1 biryani 7359e96（11-03）    840  1,154  1,380  1,697  2,054  2,168  2,259  2,296 MB
  4.1.0-pre1 biryani c417f0f（11-04）    745  1,147  1,439  1,514  1,819  2,049  2,345  2,548 MB
  4.0.5      biryani 7359e96（11-03）     87     99    137    169    176    205    217    239 MB
  4.0.5      biryani c417f0f（11-04）     86    102    118    123    125    130    148    151 MB
  ```

  - 11-03 は VM 4 GB、11-04 は 8 GiB。biryani `7359e96` までは、peer が切断しても Connection Ractor が終わらなかった（[internals/biryani-ractor-architecture](../internals/biryani-ractor-architecture.md)）。
    `c417f0f` では、各 run の 3 秒後に生きている Ractor は 2 個（main とサーバー）だけで、Connection Ractor は残っていない
  - 11-03 の計測では増分が小さくなっていったので「頭打ちに向かう」と書いたが、11-04 の計測では 8 回目まで +200〜300 MB ずつ増え続けた。**8 回では頭打ちになるとは言えない**
  - 4.0.5 は、Connection Ractor が終わるようになって増え方が小さくなった（239 → 151 MB）。4.1.0-preview1 は Connection Ractor が終わっても増え続けるので、主な原因は Connection Ractor の取り残しではない

- **VM を 8 GiB にした後の `bench_c` / `bench_m`**（4.1.0-preview1。`bench_c` は 10,000 リクエストの run を 4 回、`bench_m` は 6 回）:

  | biryani | `bench_c` | `bench_m` |
  |---|---|---|
  | `7359e96` | 成功（最大 RSS 4.7 GB） | 3 回中 2 回成功（5.1 GB / 5.0 GB）、1 回は OOM で kill（7.5 GB） |
  | `c417f0f` | 成功（4.5 GB） | 3 回とも最後の `-m100`（同時 Ractor 約 5,100）の run で OOM で kill（7.5〜7.7 GB） |

  8 GiB でも `bench_m` は安定して通らない。biryani `c417f0f` のほうが kill されやすいが、回数が少なく、差があるとは言い切れない。
  原因の候補: `c417f0f` では各 run の終わりに、多数のリクエストを処理した Connection Ractor が終了する。そのたびに大きな objspace の retire GC と absorb が走る（未検証）

### 4. プール化で回避できる

biryani の Stream Ractor をワーカーのプールに差し替えると（`load/ractor_pool_shim.rb`）、master での objspace 生成・retire GC・absorb の回数は 10,000 回強から約 60 回になった。
スループットは 2,959 → 20,754 req/s で 4.0.5（プールありで 18,641 req/s）を上回り、最大 RSS は 2.2 GB → 55 MB になった。
per-Ractor GC のコストは、Ractor を作っては捨てる使い方のときに表に出る（[scenarios/stream-ractor-pool](../scenarios/stream-ractor-pool.md)）。

## 関連ページ

- [scenarios/stream-ractor-pool](../scenarios/stream-ractor-pool.md) — プール化で回避した計測

- [scenarios/ruby-master-vs-405](../scenarios/ruby-master-vs-405.md)
- [contributions/objspace-absorb-free-pages-tail](../contributions/objspace-absorb-free-pages-tail.md)
- [internals/upstream-scheduler-changes-2026](../internals/upstream-scheduler-changes-2026.md) — per-Ractor GC の概要
- [internals/ractor-local-gc-status](../internals/ractor-local-gc-status.md) — Ruby 4.0.2 時点の Ractor-local GC
- [findings/ractor-pool-feasibility](ractor-pool-feasibility.md) — Stream Ractor をプールすれば、このコストの大半を避けられる
- [questions/README](../questions/README.md) — Q8
