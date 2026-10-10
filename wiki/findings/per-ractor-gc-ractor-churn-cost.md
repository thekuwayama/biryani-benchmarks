---
date: 2026-10-11
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
| [`rb_gc_impl_objspace_alloc`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc/default/default.c#L13350-L13360) | 10,055 | 1 |
| [`rb_gc_impl_objspace_retire_gc`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc/default/default.c#L8685-L8707) | 10,053 | 1 |
| [`objspace_absorb`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc/default/default.c#L9996-L10233) | 10,053 | 1 |
| `gc_start` | 10,200 | ≈ 1（ほぼすべて retire GC） |
| `heap_page_allocate_and_initialize` | 31,041 | ≈ 3 |
| `gc_sweep_page` | 407,699 | ≈ 40 |

10,000 リクエスト = 10,000 個の Stream Ractor（+ 接続ごとの Connection / recv_loop 各 25）。
retire GC は、終了するスレッドが自分の objspace に対して `GPR_FLAG_FULL_MARK | GPR_FLAG_IMMEDIATE_SWEEP` の GC を行うもの（[`ractor.c:755`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor.c#L755) の `rb_gc_objspace_postmortem_self` 経由）。
deferred zombie を片付けた場合は 2 回目の GC も走る。

absorb 修正後の FlameGraph で上位に来るのは、この処理の中身である。

- `gc_sweep_plane` 14.4%
- `page_pool_acquire` 8.2%
- `gc_sweep_register_free_slot` 6.6%
- libc（memset など）11.8%

Ractor 生成時の空ヒープの確保・初期化と、終了時の sweep がほとんどを占める。

### 2. `objspace_absorb` の O(N²)

absorb 前の master の FlameGraph では、`objspace_absorb` の self が ruby プロセスの 58.5% を占めた。
`perf annotate` で見ると、そのサンプルの 99.6% が [`gc/default/default.c:10069`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc/default/default.c#L10066-L10072) の 1 行に集中していた。

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

absorb は次の 3 か所で起きる（[`gc.c:4693-4797`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc.c#L4693-L4797)）。

| 経路 | いつ | 吸収先 |
|------|------|-------|
| `rb_gc_objspace_absorb_into_current` | `Ractor#value` で join したとき | join した Ractor |
| `objspace_absorb_disowned_zombies` | join されないまま Ractor オブジェクトが回収されたとき（postponed job） | main Ractor |
| `rb_gc_objspace_absorb_all_zombies` | VM 終了時（[`ractor.c:1281`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor.c#L1281)） | main Ractor |

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

## 関連ページ

- [scenarios/ruby-master-vs-405](../scenarios/ruby-master-vs-405.md)
- [contributions/objspace-absorb-free-pages-tail](../contributions/objspace-absorb-free-pages-tail.md)
- [internals/upstream-scheduler-changes-2026](../internals/upstream-scheduler-changes-2026.md) — per-Ractor GC の概要
- [internals/ractor-local-gc-status](../internals/ractor-local-gc-status.md) — Ruby 4.0.2 時点の Ractor-local GC
- [findings/ractor-pool-feasibility](ractor-pool-feasibility.md) — Stream Ractor をプールすれば、このコストの大半を避けられる
- [questions/README](../questions/README.md) — Q8
