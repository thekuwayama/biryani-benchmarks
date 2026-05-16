# Wiki インデックス

biryani（Ractor HTTP/2 実装）のパフォーマンスに関する知識ベース。

最終更新: 2026-05-17

## シナリオ

- [[scenarios/baseline-default]] — デフォルトパラメータ（-n10000 -c50 -m100 -t10）: 4,981 req/s、レイテンシ 866ms mean

## 発見・観察

- [[findings/latency-stream-multiplexing]] — 高レイテンシの原因としてストリーム多重化（-m100）によるキューイング遅延を仮説
- [[findings/flamegraph-baseline-cpu-profile]] — CPU の 12% が Ractor 生成、16% が futex 同期、11% が GC（ベースライン）

## Ractor 内部実装

<!-- wiki/internals/ 以下のページ -->

（まだなし）

## 特殊ページ

- [[overview]] — Ractor パフォーマンスの現時点での総合的な理解
- [[log]] — セッションの時系列記録
