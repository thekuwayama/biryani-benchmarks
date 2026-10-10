---
date: 2026-10-11
tags: [scenario]
---

# Stream Ractor のプール化（biryani 0.0.15、Ruby 4.0.5 / master 17aeb89200）

biryani はストリームごとに Stream Ractor を作って使い捨てている。これを使い回すワーカーのプールに差し替えると、
スループットは **4.0.5 で約 2.4 倍（7,735 → 18,641 req/s）、master で約 7 倍（2,959 → 20,754 req/s）** になり、**master が 4.0.5 を上回った**。
master では、per-Ractor GC のコスト（Ractor ごとの objspace 生成・retire GC・absorb）がワーカー数ぶんの回数に減り、最大 RSS も 2.2 GB から 55 MB になった。
4.0.5 でも効果が大きいので、Ractor の使い捨てそのものが、どちらの Ruby でも主要なコストだったことになる。

## 詳細

### 条件

- Lima VM（aarch64、4 CPU、4 GB）、`h2load -c25 -m50 -t10`、`RUBY_MAX_CPU` は未設定
- 両方の Ruby に IO move シム（`BIRYANI_IO_MOVE_SHIM=1`）を入れた。理由は [scenarios/ruby-master-vs-405](ruby-master-vs-405.md) を参照
- **プールのシム** `load/ractor_pool_shim.rb`（`BIRYANI_STREAM_POOL=<ワーカー数>`）: `Biryani::Stream#initialize` を実行時に上書きする（`raw/biryani` は変更しない）
  - main Ractor が起動時にワーカーを N 個作り、shareable な定数に置く。ワーカーは `loop { Ractor.receive → proc.call → tx.send }` を続け、終了しない
  - Connection からの `rx.send(req, move: true)` を、ランダムに選んだワーカーへの `[req, stream_id, tx, proc]` の送信に置き換える
  - stream_id はどの接続でも 1, 3, 5... と同じ値になるので、ワーカーの振り分けには使わない
  - エラー時に Connection が送る `nil`（Stream Ractor を終わらせる合図）は無視する
- スクリプト: `load/bench_compare_rubies.rb`（3 回、毎回サーバーを起動し直す）、`load/server_c25_m50.rb`（RSS・uprobe・FlameGraph 用）

### スループット（`-n10000`、3 回平均、req/s、失敗 0）

| プールサイズ | 4.0.5 | master `17aeb89200` |
|---|---|---|
| なし（[ruby-master-vs-405](ruby-master-vs-405.md)） | 7,735 | 2,959 |
| **4** | **18,641** | **20,754** |
| 8 | 17,956 | 20,372 |
| 16 | 17,206 | 20,727 |
| 64 | 15,905 | 20,605 |

- 4.0.5 は、プールを大きくするほど少しずつ下がる（4 → 64 で -15%）。master はプールサイズによらずほぼ一定
- 平均レイテンシ: 4.0.5 は 52〜65 ms（sd 12〜20 ms）、master は 46〜47 ms（sd 6〜10 ms）。プールなしの 4.0.5（130〜140 ms）の 3 分の 1 程度

<details><summary>各回の値</summary>

| Ruby | プール | run1 | run2 | run3 |
|---|---|---|---|---|
| 4.0.5 | 4 | 18,855 | 18,070 | 18,997 |
| | 8 | 17,938 | 18,905 | 17,026 |
| | 16 | 17,600 | 17,330 | 16,687 |
| | 64 | 15,461 | 16,139 | 16,114 |
| master | 4 | 20,971 | 20,698 | 20,593 |
| | 8 | 20,490 | 20,236 | 20,391 |
| | 16 | 20,213 | 20,831 | 21,137 |
| | 64 | 20,706 | 20,430 | 20,679 |

</details>

`-n10000` だと 1 回が約 0.5 秒で終わってしまうので、5 倍の `-n50000`（プール 8）でも確かめた。

| | 4.0.5 | master |
|---|---|---|
| req/s（3 回平均） | 20,660（21,011 / 20,252 / 20,716） | **21,762**（21,768 / 21,752 / 21,765） |
| 平均レイテンシ | 48〜49 ms | 46 ms |
| sd | 9〜10 ms | **4〜5 ms** |

master のほうが約 5% 速く、ばらつきも半分以下だった。

### メモリと per-Ractor GC の呼び出し回数（プール 8、`-n10000`）

| | 4.0.5 なし | 4.0.5 プール | master なし | master プール |
|---|---|---|---|---|
| 最大 RSS | 106 MB | 32 MB | 2,197 MB | **55 MB** |
| minor page faults | 52,794 | 17,361 | 597,298 | 24,023 |
| プロセス全体の wall time | 1.52 s | 0.87 s | 9.15 s | 0.65 s |

master の uprobe の回数（1 回の実行分）:

| 関数 | プールなし | プール 8 |
|---|---|---|
| `rb_gc_impl_objspace_alloc` | 10,055 | **63** |
| `rb_gc_impl_objspace_retire_gc` | 10,053 | **61** |
| `objspace_absorb` | 10,053 | **61** |
| `gc_start` | 10,200 | 1,985 |
| `heap_page_allocate_and_initialize` | 31,041 | 2,465 |
| `gc_sweep_page` | 407,699 | 16,980 |

- 残った 63 は、ワーカー 8 + Connection 25 + recv_loop 25 + main などの分
- プールありでも `gc_start` が約 2,000 回あるのは、各 Ractor が自分のヒープに対して行う通常のローカル GC
- 「プールなし」の回数は absorb 修正の実験ビルドで数えた値（[findings/per-ractor-gc-ractor-churn-cost](../findings/per-ractor-gc-ractor-churn-cost.md)）。修正はリストの連結方法だけなので、呼び出し回数は変わらない

### FlameGraph（プール 8、`-n50000`、`perf -F 499 --call-graph dwarf -m 64M`、ruby プロセス内の inclusive）

| | 4.0.5 なし | 4.0.5 プール | master なし | master プール |
|---|---|---|---|---|
| `vm_exec_core`（Ruby の実行） | 11.6% | **20.7%** | 2.9% | **25.7%** |
| GC 全体 | 19.3% | 10.6% | 72.6% | 14.6% |
| futex | 17.2% | 6.5% | 1.9% | 1.1% |
| `thread_create_core` | 3.0% | 0.0% | 0.1% | 0.0% |
| heap page の確保・解放 | 0.7% | 0.3% | 10.0% | 0.2% |
| malloc / free | 2.3% | 2.6% | 0.6% | 3.8% |

- 「なし」の列は `-n10000` の計測（[ruby-master-vs-405](ruby-master-vs-405.md)）
- プールを入れると、どちらの Ruby でも、Ractor の生成・終了に伴う GC や futex が減り、Ruby のコードを実行している割合が増える
- master は futex がほぼ消えている（1.1%）。4.0.5 は 6.5% 残る
- SVG: `raw/flamegraphs/flamegraph_c25_m50_ruby405_biryani015_pool8.svg`、`flamegraph_c25_m50_master17aeb_biryani015_pool8.svg`

### 読み取れること

1. **Ractor の使い捨ては、4.0.5 でもスループットの半分以上を食っていた**。以前の Q3 では「プールの効果は限定的」と予想していたが、外れていた（[findings/ractor-pool-feasibility](../findings/ractor-pool-feasibility.md)）
2. **master の後退は、ほぼすべて Ractor ごとの固定コストによるもの**だった。プールでそれを避けると master は 4.0.5 より速く、ばらつきも小さい。per-Ractor GC は、Ractor を長く使う設計なら利点のほうが大きい
3. biryani 側の対応候補（ruby/ruby への contributions ではない）: Stream Ractor のプール化を biryani 本体に入れる。その場合、遅いハンドラで後ろが詰まる問題（ランダム振り分けの限界）と、ワーカーが落ちたときの扱いを決める必要がある

## 関連ページ

- [ruby-master-vs-405](ruby-master-vs-405.md) — プールなしの比較
- [findings/per-ractor-gc-ractor-churn-cost](../findings/per-ractor-gc-ractor-churn-cost.md)
- [findings/ractor-pool-feasibility](../findings/ractor-pool-feasibility.md) — Q3（プールの実現可能性。予想を訂正）
- [internals/biryani-ractor-architecture](../internals/biryani-ractor-architecture.md)
- [questions/README](../questions/README.md) — Q9
