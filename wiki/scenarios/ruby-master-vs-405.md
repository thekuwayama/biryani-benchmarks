---
date: 2026-10-11
tags: [scenario]
---

# Ruby 4.0.5 vs master 17aeb89200（biryani 0.0.15、-c25 -m50）

biryani 0.0.15 を Ruby 4.0.5 と master `17aeb89200` で比べた。master は **4.0.5 の約 43% のスループット**（約 3,400 vs 約 8,000 req/s）で、
最大 RSS は **約 20 倍**（2.2 GB vs 106 MB）になった。原因は per-Ractor GC で、Ractor を 1 つ使い捨てるたびに objspace の生成・retire GC・absorb が走る。
詳しい分析は [findings/per-ractor-gc-ractor-churn-cost](../findings/per-ractor-gc-ractor-churn-cost.md) にまとめた。

## 詳細

### 条件

- Lima VM（aarch64、4 CPU、4 GB）、`h2load -n10000 -c25 -m50 -t10`
- master は Lima VM 上で `17aeb89200` をビルド（4.0.5 と同じ configure: `--enable-shared --with-ext=openssl,psych,+ --disable-install-doc`、`-O3 -ggdb3`）
- **IO move シム**: master では IO を Ractor にコピーで渡せない（[findings/ractor-io-copy-regression](../findings/ractor-io-copy-regression.md)）。
  そのため biryani の IO 受け渡しを move に差し替える `load/ractor_io_move_shim.rb` を、比較の公平さのため**両方の Ruby に**読み込んだ
- スクリプト: `load/bench_compare_rubies.rb`（`RUBY_MAX_CPU` ごとに 3 回、毎回サーバーを起動し直す）
- master の 4.0.5 との違いには `default_max_cpu`（4.0.5 は 8 固定、master は CPU 数 = 4）も含まれる。そのため `RUBY_MAX_CPU` を 4 と 8 に固定した場合も測った

### スループット（3 回平均、req/s）

| RUBY_MAX_CPU | 4.0.5（シムなし） | 4.0.5（シムあり） | master（シムあり） | master + absorb 修正（シムあり） |
|---|---|---|---|---|
| unset | 8,238 | 7,735 | 2,959 | 3,335 |
| 4 | 8,756 | 8,382 | 3,540 | 3,347 |
| 8 | 8,036 | 7,907 | 3,508 | 3,571 |

- 各回の値は下の表を参照。失敗リクエストはどの条件でも 0
- シム自体のコストは 4.0.5 で 2〜6%（ばらつきの範囲と区別しにくい）
- master の平均レイテンシは 250〜400 ms で、4.0.5（120〜140 ms）の約 2 倍
- 「absorb 修正」は、`objspace_absorb` の free page チェーン連結を O(N²) から O(src) に直した実験ビルド（[contributions/objspace-absorb-free-pages-tail](../contributions/objspace-absorb-free-pages-tail.md)）。リクエスト中のスループットは変わらない

<details><summary>各回の値</summary>

| 条件 | RUBY_MAX_CPU | run1 | run2 | run3 |
|---|---|---|---|---|
| 4.0.5 シムなし | unset | 8,484 | 7,971 | 8,259 |
| | 4 | 8,841 | 8,714 | 8,714 |
| | 8 | 8,029 | 8,392 | 7,688 |
| 4.0.5 シムあり | unset | 7,402 | 7,596 | 8,208 |
| | 4 | 8,444 | 8,550 | 8,150 |
| | 8 | 7,910 | 7,872 | 7,940 |
| master シムあり | unset | 2,414 | 2,844 | 3,619 |
| | 4 | 3,495 | 3,413 | 3,710 |
| | 8 | 3,365 | 3,506 | 3,652 |
| master + absorb 修正 | unset | 3,027 | 3,344 | 3,634 |
| | 4 | 3,366 | 3,178 | 3,497 |
| | 8 | 3,763 | 3,457 | 3,494 |

</details>

### メモリ・プロセス時間（`/usr/bin/time -v`、`load/server_c25_m50.rb`、シムあり）

| | 4.0.5 | master | master + absorb 修正 |
|---|---|---|---|
| 最大 RSS | 106 MB | 2,197 MB | 2,202 MB |
| minor page faults | 52,794 | 597,298 | 597,622 |
| プロセス全体の wall time | 1.52 s | 9.15 s | 3.81 s |
| うち h2load | 1.21 s | 2.99 s | 3.35 s |

master は h2load の終了後にも約 6 秒かかっている。これは終了時に残った Ractor の objspace を main にまとめて absorb する処理で、absorb 修正で約 0.5 秒に縮んだ。

最初に perf の既定バッファ（`-m 512M`）で master を計測したときは、VM（4 GB）が OOM になり、サーバーが SIGKILL された（h2load で 3,000〜4,000 件の失敗）。以降は `-m 64M` で計測した。

### FlameGraph（`perf -F 499 --call-graph dwarf -m 64M`、ruby プロセス内の inclusive 比率）

| | 4.0.5 | master | master + absorb 修正 |
|---|---|---|---|
| GC 全体（`gc_*` / `rb_gc*` / `objspace*`） | 19.3% | 72.6% | 38.7% |
| `objspace_absorb`（self） | — | **58.5%** | ほぼ 0 |
| heap page の確保・解放 | 0.7% | 10.0% | 20.5% |
| memset / memcpy | 1.7% | 4.7% | 9.6% |
| page fault | 1.5% | 3.1% | 6.3% |
| futex | 17.2% | 1.9% | 4.9% |
| `thread_create_core` | 3.0% | 0.1% | 0.3% |
| `vm_exec_core` | 11.6% | 2.9% | 7.1% |

- master の FlameGraph は h2load 後の終了処理（約 6 秒）も含むので、`objspace_absorb` の比率は終了処理が大半を占める
- absorb 修正後の上位 self フレームは `gc_sweep_plane` 14.4%、`page_pool_acquire` 8.2%、`gc_sweep_register_free_slot` 6.6%。Ractor ごとの heap 初期化と retire GC が支配的
- SVG: `raw/flamegraphs/flamegraph_c25_m50_ruby405_biryani015.svg`、`flamegraph_c25_m50_master17aeb_biryani015.svg`、`flamegraph_c25_m50_master17aeb_absorbfix_biryani015.svg`

### 4.0.5 での biryani 0.0.12 → 0.0.15 の変化（参考）

4.0.5・シムなし・`RUBY_MAX_CPU` unset で、biryani 0.0.15 は 8,238 req/s だった（0.0.12 は 7,464 req/s、[sweep-ruby-max-cpu](sweep-ruby-max-cpu.md) 第 3 回）。
biryani の変更だけで約 +10% になる。

FlameGraph でも futex 17.2%、GC 19.3% と、4.0.2 + 0.0.12 の内訳（futex ~11%、GC ~8%）から変わっている。
ただし今回はサンプリング周波数（99 → 499 Hz）も変えているため、単純には比べられない。

### rperf

今回は取っていない（master の問題が GC 内部にあり、Ruby レベルの wall time では見えないため優先度を下げた）。

## 関連ページ

- [findings/per-ractor-gc-ractor-churn-cost](../findings/per-ractor-gc-ractor-churn-cost.md)
- [findings/ractor-io-copy-regression](../findings/ractor-io-copy-regression.md)
- [contributions/objspace-absorb-free-pages-tail](../contributions/objspace-absorb-free-pages-tail.md)
- [sweep-ruby-max-cpu](sweep-ruby-max-cpu.md)
- [internals/upstream-scheduler-changes-2026](../internals/upstream-scheduler-changes-2026.md)
