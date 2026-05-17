---
date: 2026-05-17
tags: [question]
---

# Questions — ruby/ruby に問いたい疑問

ここには ruby/ruby の Ractor 実装に関する未解決の疑問を記録する。
十分に裏付けが取れたものは `[[contributions/]]` に昇格させる。

## 未解決の疑問リスト

### Q5: M:N モード下での FlameGraph の `thread_create_core` の解釈

非 main Ractor は M:N スケジューラを使うため、biryani の 1,300 Ractors は最大 N=8 OS スレッドを共有する。
それにもかかわらず FlameGraph では `thread_create_core` + `nt_alloc_stack` が ~10% 現れている。

- ブロッキング I/O（`IO#read`）のたびに追加の OS スレッドが生成されているのか？
- SNT プールの初期構築コストが計上されているのか？
- `RUBY_MAX_CPU` を変えるとどう変化するか？

関連: [[internals/ractor-overview]], [[findings/flamegraph-c25-m50-vs-baseline]]



### Q1: `Ractor.select` の 33.5% は何を待っているのか

rperf wall モードで `-c25 -m50` を計測すると `Ractor.select` が wall time の 33.5% を占める。この待機時間の内訳を知りたい：
- recv_loop から来るフレーム受信の待機か
- Stream Ractor からのレスポンス待機か
- その比率はどうか

関連: [[findings/rperf-wall-vs-perf-cpu]], [[internals/biryani-ractor-architecture]]

### Q2: `IO#read` の 47.9% はブロッキング I/O か

biryani はノンブロッキング I/O を使っていないため、47.9% がソケット読み込み待ちになっている。
Ractor とノンブロッキング I/O の組み合わせは可能か？ 仮に `io_uring` や `epoll` を使えば構造的に変わるか？

関連: [[findings/rperf-wall-vs-perf-cpu]]

### Q3: Ractor プールは実装可能か、効果があるか

perf の CPU プロファイルでは Ractor 生成（スレッド生成）が ~10%。
ただし rperf wall では `Ractor.new` は 0.0%。

wall time ではほぼゼロだが、CPU サイクルを消費している。Ractor をプールして再利用すれば CPU 効率が上がるか？ ruby/ruby の Ractor は使い捨て前提の設計か？

関連: [[internals/biryani-ractor-architecture]], [[findings/flamegraph-c25-m50-vs-baseline]]

### Q4: `pthread_cond_broadcast` を避けられるか（→ 調査済み）

`Ractor::Port#send` は毎回 `pthread_cond_broadcast`（futex）を発行する。

**調査結果** (`[[internals/ractor-sync-wakeup]]`):
- `rb_ractor_sched_wakeup` は `th` 引数を受け取るが**完全に無視**し、常に broadcast
- 1 Ractor = 1 スレッドなので `pthread_cond_signal` で意味的に正確かつ同等
- `rb_native_cond_signal` はコードベースに存在し多数の箇所で利用されている

→ PR 候補に昇格: `[[contributions/cond-signal-vs-broadcast]]`

関連: [[internals/ractor-port-implementation]], [[internals/ractor-sync-wakeup]]
