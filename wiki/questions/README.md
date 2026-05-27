---
date: 2026-05-17
tags: [question]
---

# Questions — ruby/ruby に問いたい疑問

ここには ruby/ruby の Ractor 実装に関する未解決の疑問を記録する。
十分に裏付けが取れたものは [contributions/](../contributions/) に昇格させる。

## 未解決の疑問リスト

### Q5: M:N モード下での FlameGraph の `thread_create_core` の解釈（→ 解決）

**回答**（2026-05-17）:

`thread_create_core` ~10% は **SNT プール補充（replenishment）コスト**。

`IO#read` → `native_thread_dedicated_inc` → `snt_cnt` 減少 → タイマー or Ractor 生成時に
`native_thread_check_and_create_shared` が `pthread_create` で新 SNT を生成。
biryani の高 I/O 頻度によりこのサイクルが連続する。

詳細: [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md)

コントリビュート候補: [contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md)

関連: [internals/ractor-overview](../internals/ractor-overview.md), [findings/flamegraph-c25-m50-vs-baseline](../findings/flamegraph-c25-m50-vs-baseline.md)



### Q1: `Ractor.select` の 33.5% は何を待っているのか（→ 解決）

**回答**（2026-05-23）:

**主因**: recv_loop の `IO#read` がブロックしている間、select_loop も `Ractor.select` で並行待機している時間。
両者は異なる Ractor で動くため wall time はそれぞれに独立してカウントされる。

**副因**: Stream Ractor のレスポンス待機（`proc.call` が trivial なため寄与は微小）。

C 実装では `ractor_selector__wait`（ractor_sync.c:1420）が毎 wakeup でポートを全スキャンし、
メッセージがなければ `rb_ractor_sched_wait`（thread_pthread.c:1330）経由で M:N スケジューラに入る。
これはブロッキング I/O アーキテクチャの **構造的な必然**。

詳細: [findings/ractor-select-wait-breakdown](../findings/ractor-select-wait-breakdown.md)

実装: [internals/ractor-select-implementation](../internals/ractor-select-implementation.md)

### Q2: `IO#read` の 47.9% はブロッキング I/O か

biryani はノンブロッキング I/O を使っていないため、47.9% がソケット読み込み待ちになっている。
Ractor とノンブロッキング I/O の組み合わせは可能か？ 仮に `io_uring` や `epoll` を使えば構造的に変わるか？

関連: [findings/rperf-wall-vs-perf-cpu](../findings/rperf-wall-vs-perf-cpu.md)

### Q3: Ractor プールは実装可能か、効果があるか（→ 解決）

**回答**（2026-05-23）:

- **実装は可能**: ループ型 Ractor（`loop { Ractor.recv; ... }`）で実現できる。idle 時は M:N スケジューラが SNT を解放するため、プール Ractor は SNT を占有しない。
- **thread_create_core ~10% への効果は限定的**: SNT 補充の必要性を作るのは `IO#read` → `native_thread_dedicated_inc` → `snt_cnt--` の連鎖。Stream Ractor.new を減らしても IO#read は変わらないため、補充頻度はほぼ変わらない。
- **GC ~8% への軽微な効果**: 短命 Ractor オブジェクトの減少で若干改善する可能性（未定量）。
- **ruby/ruby の設計思想**: M:N スケジューラで使い捨てコストを吸収する設計。プールは application-level の最適化。

詳細: [findings/ractor-pool-feasibility](../findings/ractor-pool-feasibility.md)

### Q4: `pthread_cond_broadcast` を避けられるか（→ クローズ：誤分析）

~~`Ractor::Port#send` は毎回 `pthread_cond_broadcast`（futex）を発行する。~~

**再調査結果**（2026-05-17）:
`rb_ractor_sched_wakeup` の `pthread_cond_broadcast` は `#else // win32` ブロック内。
**Linux (pthread) では走らない。** pthread 版は `thread_pthread.c:1366` で `r_th` を直接使い、
M:N スケジューラ経由で `rb_native_cond_signal`（すでに signal）を発行する。

→ [contributions/cond-signal-vs-broadcast](../contributions/cond-signal-vs-broadcast.md) はクローズ。

### Q6: dedicated SNT の生成コストを下げられるか（→ 調査中）

FlameGraph の `thread_create_core` ~10% と futex ~11% が合算 ~21% を占める。

**2026-05-24 調査結果**:

`SNT_KEEP_SECONDS = 0` が根本の一因。`default_max_cpu`（提出済み）と同じ commit で
ko1 が導入した「SNT アイドルタイムアウト」機能だが、デフォルト 0 で無効化されたまま。

```
max_cpu          → SNT プールの上限（成長の制御）← 解決済み
SNT_KEEP_SECONDS → SNT プールの縮小速度（解放）← 未設定、プールが縮まらない
```

`SNT_KEEP_SECONDS > 0` にすると、アイドル SNT が N 秒でタイムアウト終了する仕組みが
コード内に実装済み（`thread_pthread.c:1286-1304`）。biryani 常時高負荷では即効性は低いが、
bursty ワークロードでのピーク後に SNT プールが縮小するようになる。

`thread_create_core` ~10% の直接原因（IO#read → dedicated_inc → 補充 → dedicated_dec → 過剰）は
`SNT_KEEP_SECONDS` では解決しない。こちらはヒステリシス（案 A）が必要。

**次の実験**: Ruby を `SNT_KEEP_SECONDS = 5` でコンパイルして biryani ベンチマーク実行し、
FlameGraph の `thread_create_core` 比率の変化を確認する。

詳細: [findings/snt-keep-seconds-disabled](../findings/snt-keep-seconds-disabled.md), [contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md)

関連: [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md), [findings/futex-mn-scheduler-dedicated-nt](../findings/futex-mn-scheduler-dedicated-nt.md)
