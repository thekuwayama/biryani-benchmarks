# Wiki インデックス

biryani（Ractor HTTP/2 実装）のパフォーマンスに関する知識ベース。

最終更新: 2026-05-17

## シナリオ

- [[scenarios/baseline-default]] — デフォルトパラメータ（-n10000 -c50 -m100 -t10）: 4,981 req/s、レイテンシ 866ms mean
- [[scenarios/sweep-m-parameter]] — `-m` スイープ（m=1〜100）: ピークは m=50 の 6,183 req/s。m=100 で逆に低下。レイテンシは m に線形比例
- [[scenarios/sweep-c-parameter]] — `-c` スイープ（c=10〜100、m=50 固定）: ピークは c=25 の 7,695 req/s。c=50 より 13% 高スループット・レイテンシ 2.5× 低

## 発見・観察

- [[findings/latency-stream-multiplexing]] — 高レイテンシの原因としてストリーム多重化（-m100）によるキューイング遅延を仮説
- [[findings/flamegraph-baseline-cpu-profile]] — CPU の 12% が Ractor 生成、16% が futex 同期、11% が GC（ベースライン）

## Ractor 内部実装

- [[internals/ractor-architecture]] — biryani の Ractor 構造：接続ごと + recv_loop + ストリームごとに Ractor 生成。-c50 -m100 で最大 5,100 Ractor
- [[internals/ractor-port-implementation]] — Ractor::Port の C 実装：recv_queue 二段キュー設計、1送信=1 pthread_cond_broadcast=1 futex syscall

## 特殊ページ

- [[overview]] — Ractor パフォーマンスの現時点での総合的な理解
- [[log]] — セッションの時系列記録
