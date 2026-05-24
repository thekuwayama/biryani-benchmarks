# Wiki インデックス

**ゴール**: ruby/ruby の Ractor にパフォーマンス関連のコントリビュートをする。

最終更新: 2026-05-24（SNT_KEEP_SECONDS finding・pool-growth-shrink 図解追加・Q6 調査中）

---

## 特殊ページ

- [overview](overview.md) — 現時点の総合的理解とコントリビュート候補
- [log](log.md) — セッションの時系列記録

---

## シナリオ

- [scenarios/baseline-default](scenarios/baseline-default.md) — デフォルト（-c50 -m100）: 4,981 req/s、latency 866ms
- [scenarios/sweep-m-parameter](scenarios/sweep-m-parameter.md) — `-m` スイープ（1〜100）: ピーク m=50、6,183 req/s。レイテンシは m に線形比例
- [scenarios/sweep-c-parameter](scenarios/sweep-c-parameter.md) — `-c` スイープ（10〜100、m=50 固定）: ピーク c=25、7,695 req/s（全体最高）
- [scenarios/sweep-ruby-max-cpu](scenarios/sweep-ruby-max-cpu.md) — **RUBY_MAX_CPU スイープ（I/O バウンド）**: ピーク cpu=4、8,456 req/s。デフォルト8より+3.1%
- [scenarios/sweep-ruby-max-cpu-cpu-bound](scenarios/sweep-ruby-max-cpu-cpu-bound.md) — **RUBY_MAX_CPU スイープ（CPU バウンド）**: ピーク cpu=4、1,317 req/s。デフォルト8より+5.5%

---

## 発見・観察

- [findings/latency-stream-multiplexing](findings/latency-stream-multiplexing.md) — 高レイテンシはストリーム多重化によるキューイング遅延が主因という仮説
- [findings/flamegraph-baseline-cpu-profile](findings/flamegraph-baseline-cpu-profile.md) — CPU: Ractor 生成 12%、futex 16%、GC 11%（ベースライン）
- [findings/flamegraph-c25-m50-vs-baseline](findings/flamegraph-c25-m50-vs-baseline.md) — -c25 -m50 で有効 CPU 仕事増（vm_exec_core 10%→14%）
- [findings/rperf-wall-vs-perf-cpu](findings/rperf-wall-vs-perf-cpu.md) — **大発見**: biryani は I/O バウンド。IO#read 47.9%、Ractor.new 0.0%
- [findings/futex-mn-scheduler-dedicated-nt](findings/futex-mn-scheduler-dedicated-nt.md) — futex ~11% の真因：ブロッキング I/O → dedicated SNT の cond_signal/wait
- [findings/ractor-select-wait-breakdown](findings/ractor-select-wait-breakdown.md) — **Q1 解答**: Ractor.select 33.5% はブロッキング I/O との並行待機（構造的必然）
- [findings/rperf-concurrent-vs-parallel](findings/rperf-concurrent-vs-parallel.md) — rperf の計測モデル：各 Ractor 独立の並行計測であり、実時間（並列）の重複を含む
- [findings/ractor-pool-feasibility](findings/ractor-pool-feasibility.md) — **Q3 解答**: Ractor プールは実装可能。ただし thread_create_core ~10% への効果は限定的（原因は IO#read）
- [findings/snt-keep-seconds-disabled](findings/snt-keep-seconds-disabled.md) — `SNT_KEEP_SECONDS = 0` により SNT プールが実行時に縮小しない（Q6 調査中）

---

## Ractor 内部実装

- [internals/ractor-overview](internals/ractor-overview.md) — Ractor 全体像（OS マッピング・ライフサイクル・共有モデル・API）
- [internals/biryani-ractor-architecture](internals/biryani-ractor-architecture.md) — biryani の Ractor 構造（接続 + recv_loop + ストリームごと生成）
- [internals/ractor-port-implementation](internals/ractor-port-implementation.md) — Ractor::Port の C 実装（recv_queue 二段キュー）
- [internals/ractor-sync-wakeup](internals/ractor-sync-wakeup.md) — wakeup メカニズム精査（Win32 vs pthread 分岐・M:N スケジューラの実際のパス）
- [internals/ractor-mn-snt-lifecycle](internals/ractor-mn-snt-lifecycle.md) — **Q5 解答**: SNT ライフサイクルと補充ロジック（thread_create_core ~10% の真因）
- [internals/ractor-select-implementation](internals/ractor-select-implementation.md) — `Ractor.select` の C 実装（ポーリングループ・Linux/Win32 分岐・M:N スケジューラとの接続）
- [internals/mn-snt-pool-growth-shrink](internals/mn-snt-pool-growth-shrink.md) — `max_cpu`（成長上限）と `SNT_KEEP_SECONDS`（縮小速度）の役割と時系列シナリオ（Mermaid 図付き）
- [internals/ractor-local-gc-status](internals/ractor-local-gc-status.md) — Ractor-local GC の現状（Ruby 4.0.2）：ko1 RubyKaigi 2025 講演との対比、インフラは布石段階、本体は未実装

---

## 未解決の疑問

- [questions/README](questions/README.md) — Q1〜Q6（Q1・Q3・Q4・Q5 解決済み。Q2: IO#read ノンブロッキック化。Q6: 調査中 — SNT_KEEP_SECONDS が SNT 縮小の鍵）

---

## コントリビュート候補

- [contributions/default-max-cpu-cpu-count](contributions/default-max-cpu-cpu-count.md) — **★ 変更案確定・PR 提出待ち**: `default_max_cpu=8` → 物理 CPU 数に変更（I/O +3.1%・CPU +5.5%・変更後コード確定）
- [contributions/snt-replenishment-overhead](contributions/snt-replenishment-overhead.md) — **調査中**: SNT 補充の頻繁な pthread_create を削減（CPU ~10%）。SNT_KEEP_SECONDS 有効化が候補案

### クローズ済み

- [contributions/cond-signal-vs-broadcast](contributions/cond-signal-vs-broadcast.md) — ~~broadcast → signal~~（前提誤り：Linux では broadcast は走らない）
