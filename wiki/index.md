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

---

## 発見・観察

- [[findings/latency-stream-multiplexing]] — 高レイテンシはストリーム多重化によるキューイング遅延が主因という仮説
- [[findings/flamegraph-baseline-cpu-profile]] — CPU: Ractor 生成 12%、futex 16%、GC 11%（ベースライン）
- [[findings/flamegraph-c25-m50-vs-baseline]] — -c25 -m50 で有効 CPU 仕事増（vm_exec_core 10%→14%）
- [[findings/rperf-wall-vs-perf-cpu]] — **大発見**: biryani は I/O バウンド。IO#read 47.9%、Ractor.new 0.0%

---

## Ractor 内部実装

- [[internals/ractor-architecture]] — biryani の Ractor 構造（接続 + recv_loop + ストリームごと生成）
- [[internals/ractor-port-implementation]] — Ractor::Port の C 実装（recv_queue 二段キュー、1送信=1 futex）

---

## 未解決の疑問

- [[questions/README]] — ruby/ruby に問いたい疑問 4 件

---

## コントリビュート候補

- [[contributions/README]] — 現時点では候補なし（疑問を深掘り中）
