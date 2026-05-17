# Wiki インデックス

**ゴール**: ruby/ruby の Ractor にパフォーマンス関連のコントリビュートをする。

最終更新: 2026-05-17

---

## 特殊ページ

- [[overview]] — 現時点の総合的理解とコントリビュート候補
- [[log]] — セッションの時系列記録

---

## シナリオ

- [[scenarios/baseline-default]] — デフォルト（-c50 -m100）: 4,981 req/s、latency 866ms
- [[scenarios/sweep-m-parameter]] — `-m` スイープ（1〜100）: ピーク m=50、6,183 req/s。レイテンシは m に線形比例
- [[scenarios/sweep-c-parameter]] — `-c` スイープ（10〜100、m=50 固定）: ピーク c=25、7,695 req/s（全体最高）
- [[scenarios/sweep-ruby-max-cpu]] — **RUBY_MAX_CPU スイープ**: ピーク cpu=4（物理コア数）、8,456 req/s。デフォルト8より+3%

---

## 発見・観察

- [[findings/latency-stream-multiplexing]] — 高レイテンシはストリーム多重化によるキューイング遅延が主因という仮説
- [[findings/flamegraph-baseline-cpu-profile]] — CPU: Ractor 生成 12%、futex 16%、GC 11%（ベースライン）
- [[findings/flamegraph-c25-m50-vs-baseline]] — -c25 -m50 で有効 CPU 仕事増（vm_exec_core 10%→14%）
- [[findings/rperf-wall-vs-perf-cpu]] — **大発見**: biryani は I/O バウンド。IO#read 47.9%、Ractor.new 0.0%
- [[findings/futex-mn-scheduler-dedicated-nt]] — futex ~11% の真因：ブロッキング I/O → dedicated SNT の cond_signal/wait

---

## Ractor 内部実装

- [[internals/ractor-overview]] — Ractor 全体像（OS マッピング・ライフサイクル・共有モデル・API）
- [[internals/biryani-ractor-architecture]] — biryani の Ractor 構造（接続 + recv_loop + ストリームごと生成）
- [[internals/ractor-port-implementation]] — Ractor::Port の C 実装（recv_queue 二段キュー）
- [[internals/ractor-sync-wakeup]] — wakeup メカニズム精査（Win32 vs pthread 分岐・M:N スケジューラの実際のパス）
- [[internals/ractor-mn-snt-lifecycle]] — **Q5 解答**: SNT ライフサイクルと補充ロジック（thread_create_core ~10% の真因）

---

## 未解決の疑問

- [[questions/README]] — Q1〜Q6（Q4・Q5 解決済み。Q6: SNT 補充コストを下げられるか）

---

## コントリビュート候補

- [[contributions/default-max-cpu-cpu-count]] — **★ PR 候補**: `default_max_cpu=8` → 物理 CPU 数に変更（TODO コメントあり、実測 +3%）
- [[contributions/snt-replenishment-overhead]] — **候補**: SNT 補充の頻繁な pthread_create を削減（CPU ~10%）
- [[contributions/cond-signal-vs-broadcast]] — ~~broadcast → signal~~（クローズ：Win32 ブロック内のみ）
