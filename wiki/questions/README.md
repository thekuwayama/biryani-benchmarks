---
date: 2026-05-17
tags: [question]
---

# Questions — ruby/ruby に問いたい疑問

ここには ruby/ruby の Ractor 実装に関する未解決の疑問を記録する。
十分に裏付けが取れたものは `[[contributions/]]` に昇格させる。

## 未解決の疑問リスト

### Q5: M:N モード下での FlameGraph の `thread_create_core` の解釈（→ 解決）

**回答**（2026-05-17）:

`thread_create_core` ~10% は **SNT プール補充（replenishment）コスト**。

`IO#read` → `native_thread_dedicated_inc` → `snt_cnt` 減少 → タイマー or Ractor 生成時に
`native_thread_check_and_create_shared` が `pthread_create` で新 SNT を生成。
biryani の高 I/O 頻度によりこのサイクルが連続する。

詳細: [[internals/ractor-mn-snt-lifecycle]]

コントリビュート候補: [[contributions/snt-replenishment-overhead]]

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

### Q4: `pthread_cond_broadcast` を避けられるか（→ クローズ：誤分析）

~~`Ractor::Port#send` は毎回 `pthread_cond_broadcast`（futex）を発行する。~~

**再調査結果**（2026-05-17）:
`rb_ractor_sched_wakeup` の `pthread_cond_broadcast` は `#else // win32` ブロック内。
**Linux (pthread) では走らない。** pthread 版は `thread_pthread.c:1366` で `r_th` を直接使い、
M:N スケジューラ経由で `rb_native_cond_signal`（すでに signal）を発行する。

→ `[[contributions/cond-signal-vs-broadcast]]` はクローズ。

### Q6: dedicated SNT の生成コストを下げられるか

FlameGraph の futex ~11% は Ractor send ではなく、ブロッキング I/O による dedicated SNT の
`pthread_cond_wait` / `signal` が出所（`[[findings/futex-mn-scheduler-dedicated-nt]]`）。

- `IO#read` のたびに `native_thread_dedicated_inc` → dedicated SNT を確保する
- biryani の 1,300 Ractors × 複数回 IO#read = 大量の SNT 切り替え
- dedicated SNT の再利用 / プール化は可能か？
- ノンブロッキング I/O（io_uring / epoll）を使えば dedicated SNT を避けられるか？

関連: [[internals/ractor-sync-wakeup]], [[findings/futex-mn-scheduler-dedicated-nt]]
