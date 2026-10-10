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

（2026-10-11 注記: biryani v0.0.12 での計測。v0.0.14 以降の biryani は `Ractor.select` を使わず、単一ポートの `Port#receive` で待つ）

**回答**（2026-05-23）:

**主因**: recv_loop の `IO#read` がブロックしている間、select_loop も `Ractor.select` で並行待機している時間。
両者は異なる Ractor で動くため wall time はそれぞれに独立してカウントされる。

**副因**: Stream Ractor のレスポンス待機（`proc.call` が trivial なため寄与は微小）。

C 実装では `ractor_selector__wait`（ractor_sync.c:1420）が毎 wakeup でポートを全スキャンし、
メッセージがなければ `rb_ractor_sched_wait`（thread_pthread.c:1330）経由で M:N スケジューラに入る。
これはブロッキング I/O アーキテクチャの **構造的な必然**。

詳細: [findings/ractor-select-wait-breakdown](../findings/ractor-select-wait-breakdown.md)

実装: [internals/ractor-select-implementation](../internals/ractor-select-implementation.md)

### Q2: `IO#read` の 47.9% はブロッキング I/O か（→ 解決）

**回答**（2026-08-01）:

biryani は `socket.accept` で得た `IO` をブロッキングモードのまま使用している（`raw/biryani/lib/biryani/server.rb`）。
`rb_thread_io_blocking_call`（thread.c:1956、`17aeb89200` では thread.c:2203）の分岐ロジックにより、M:N スケジューラの
epoll 待ちパス（`thread_sched_wait_events`、thread_pthread_mn.c:556、`17aeb89200` では thread_sched_mn.c:536）に入るのは
`read(2)` が `EAGAIN`/`EWOULDBLOCK` を返したときだけ。ブロッキングソケットでは `read()` は
決して `EAGAIN` を返さず常にカーネル内でブロックするため、毎回 `native_thread_dedicated_inc`
（dedicated SNT 取得）を経由し、epoll パスは一度も使われない。

ソケットを `O_NONBLOCK` にすれば `read_nonblock` が `EAGAIN` で復帰 → epoll ベースの共有
`timer_thread` 監視に切り替わり、dedicated SNT を経由しなくなる。理論上は
`thread_create_core ~10%`（SNT 補充コスト）を構造的に低減できる可能性がある。ただし
これは **biryani（アプリケーションレベル）の書き換え**であり、ruby/ruby 本体の変更ではない。実測は未実施。

詳細: [internals/nonblocking-io-mn-scheduler-path](../internals/nonblocking-io-mn-scheduler-path.md)

関連: [findings/rperf-wall-vs-perf-cpu](../findings/rperf-wall-vs-perf-cpu.md), [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md)

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
**Linux (pthread) では走らない。** pthread 版は `thread_pthread.c:1428` で `r_th` を直接使い、
M:N スケジューラ経由で `rb_native_cond_signal`（すでに signal）を発行する。

→ [contributions/cond-signal-vs-broadcast](../contributions/cond-signal-vs-broadcast.md) はクローズ。

### Q6: dedicated SNT の生成コストを下げられるか（→ 一部は上流で解決、再計測待ち）

**2026-10-11 追記**: `17aeb89200` に更新したところ、ko1 が上流で SNT プールの縮小を実装していた。
`43793ca21a` で `SNT_IDLE_RETIRE` による retire が入り、`dedicated_dec` 時にプールが満杯なら retire するようになった。
`dce74ebf04` で retire 時の nt 解放が入り、`1da2eea37c` で `SNT_KEEP_SECONDS` は削除された。
下の「次の実験」（`SNT_KEEP_SECONDS = 5`）はもう成り立たない。代わりに `17aeb89200` をビルドし、`-c25 -m50` の FlameGraph で
`thread_create_core` ~10% / futex ~11% がどう変わったかを測るのが次の一手になる。
詳細: [internals/upstream-scheduler-changes-2026](../internals/upstream-scheduler-changes-2026.md)

以下は 2026-05-24 時点の記述（`e98f95b4fd` 基準）。

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

### Q7: biryani に `socket.accept.io.nonblock = true` を入れると実際どうなるか（→ 未着手）

Q2 で「原理的には epoll ベースの M:N スケジューラ経路に乗れるはず」と結論したが、これは
ソースコードの分岐ロジックからの推論であり、**実測はまだ行っていない**。

具体的な変更案（`raw/biryani/lib/biryani/server.rb:10-15`）:

```ruby
Ractor.new(socket.accept, @proc) do |io, proc|
  io.nonblock = true    # ← 追加
  conn = Connection.new(proc)
  conn.serve(io)
  io.close
end
```

これだけでは不十分で、`frame.rb:154,159`（`Frame.read` の `io.read`）と `connection.rb:308,359`
（`io.write`、preface 読み込みの `io.read`）を `read_nonblock`/`write_nonblock` + `rescue
IO::WaitReadable/WaitWritable` + リトライに書き換える必要がある。単に `nonblock = true` だけ
入れて呼び出し側を変えなければ、`read` がブロッキング前提のまま `Errno::EAGAIN` を吐いて
即座に例外で落ちる可能性が高い。

**確認したいこと**:
- 実際に FlameGraph で `thread_create_core` ~10% が下がるか
- 短命コネクション・低同時実行数で epoll 登録コストが逆にオーバーヘッドにならないか（[internals/nonblocking-io-mn-scheduler-path](../internals/nonblocking-io-mn-scheduler-path.md) のリスク欄で指摘済み）
- スループット（req/s）・レイテンシに正味のプラスがあるか

**次のステップ**: biryani の実験ブランチで上記の書き換えを行い、`-c25 -m50` で
h2load ベンチマーク＋ FlameGraph を再取得して比較する（`/biryani-benchmark` 領域）。

**2026-10-11 追記**: `17aeb89200` には `ce15950f56`（`EPOLLONESHOT` で待ちごとの `epoll_ctl` を半減）が入っている。
ノンブロッキング化した場合の上積みは、4.0.x より master のほうが大きいと予想される。
一方でブロッキング側も retire 規則で変わっているので、比較は 2×2 で行うとよい（ブロッキング／ノンブロッキング × 4.0.x／`17aeb89200`）。

詳細: [internals/nonblocking-io-mn-scheduler-path](../internals/nonblocking-io-mn-scheduler-path.md)

関連: [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md), [internals/biryani-ractor-architecture](../internals/biryani-ractor-architecture.md)

### Q8: per-Ractor GC 下で、使い捨て Ractor の「死んだヒープの回収」は stop-the-world を誘発するか（→ 一部解決）

**2026-10-11 計測結果**: STW の頻度より、**Ractor 1 つごとの固定コスト**が問題だった。master `17aeb89200` の biryani は 4.0.5 の約 43% のスループットで、最大 RSS は約 20 倍だった。

- Ractor ごとに objspace を生成し（ページ約 3 枚）、終了時には自分の objspace に full GC（retire GC）を 1 回かけ、その objspace を別の Ractor に absorb する。10,000 リクエストで、それぞれ約 10,000 回
- global GC（STW）は 1 回のマイクロベンチで 0〜2 回しか走らない。そのため終了した Ractor のメモリが 8,000〜10,000 個分（約 550 MB）たまるまで返らない
- `objspace_absorb` に O(N²) の末尾探索があった（→ [contributions/objspace-absorb-free-pages-tail](../contributions/objspace-absorb-free-pages-tail.md)）

詳細: [findings/per-ractor-gc-ractor-churn-cost](../findings/per-ractor-gc-ractor-churn-cost.md)、[scenarios/ruby-master-vs-405](../scenarios/ruby-master-vs-405.md)

残る問い: biryani で main Ractor がブロックしている間、orphan objspace の吸収（main 上の postponed job）が止まり、メモリがたまり続けるのか（仮説、未検証）。

以下は 2026-10-11 の計測前の記述。

`17aeb89200` までに per-Ractor GC が入った（`5dd63db8ea` NEWS、2026-08-04）。各 Ractor は自分のヒープを自分のスレッドで回収し、
他の Ractor は止めない。ただし NEWS によると、全 Ractor を止める GC は次の場合には走る:
明示的な `GC.start`、shareable オブジェクトの増加、**終了した Ractor のヒープの回収**（reclaiming dead Ractors' heaps）。

biryani はストリームごとに Stream Ractor を生成して使い捨てる（`-c25 -m50` で最大 1,300 Ractor が入れ替わり続ける）。
**終了した Ractor のヒープ回収が頻繁に stop-the-world を起こすなら、per-Ractor GC の恩恵を打ち消すかもしれない**。

**確認したいこと**:
- 終了した Ractor の objspace がいつ、どのロックの下で回収（absorb / merge）されるか（`e768a87a17` で「終了するスレッド自身が post-mortem で自分の objspace を回収する」ようになった点を含む）
- `GC.stat` の Ractor ごとのカウンタ（`ee4013b90f`）で、biryani 実行中のグローバル GC の回数を数える
- FlameGraph の GC ~8%（4.0.2）が `17aeb89200` でどう変わるか
- 変わらない／悪化するなら、Stream Ractor のプール化（[findings/ractor-pool-feasibility](../findings/ractor-pool-feasibility.md)）の価値が上がる

関連: [internals/upstream-scheduler-changes-2026](../internals/upstream-scheduler-changes-2026.md), [internals/ractor-local-gc-status](../internals/ractor-local-gc-status.md)
