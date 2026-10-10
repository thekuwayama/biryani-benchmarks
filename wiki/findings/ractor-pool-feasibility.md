---
date: 2026-05-23
updated: 2026-10-11
tags: [finding]
---

# Ractor プールの実現可能性と効果（Q3 解決）

> **2026-10-11 実測で訂正**: 下の結論表の「効果は限定的」という予想は外れた。
> biryani 0.0.15 の Stream Ractor をシムでプール化して測ると、スループットは **4.0.5 で約 2.4 倍（7,735 → 18,641 req/s）、master `17aeb89200` で約 7 倍（2,959 → 20,754 req/s）** になった。
> 4.0.5 でも、プールにより futex 17.2% → 6.5%、GC 19.3% → 10.6% と減り、Ruby のコードを実行している割合（`vm_exec_core`）は 11.6% → 20.7% と増えた。
> この予想は `thread_create_core` の原因（IO#read）だけを見ていて、Ractor の生成・終了に伴う GC と futex のコストを見落としていた。
> 詳細: [scenarios/stream-ractor-pool](../scenarios/stream-ractor-pool.md)

## 結論

| 問い | 答え |
|------|------|
| ループ型 Ractor プールは実装可能か | **可能** |
| idle Ractor は SNT を占有するか | **しない**（M:N スケジューラが解放） |
| thread_create_core ~10% を削減できるか | **ほぼできない**（原因は IO#read） |
| GC ~8% を軽減できるか | **わずかに可能**（短命オブジェクト削減） |
| ruby/ruby が使い捨て前提の設計か | **yes**（M:N でコストを吸収する思想） |

---

## Ractor のライフサイクル制約

```
created → running/blocking → terminated
```

状態は一方向で、終了した Ractor を再起動する API（`reset` など）は存在しない（[`ractor_core.h:83-88`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor_core.h#L83-L88)）。

## ループ型 Ractor プール（技術的に可能）

biryani の現在の Stream Ractor は一発処理で終了する設計：

```ruby
# 現在: 使い捨て（stream.rb）
Ractor.new(tx, stream_id, proc) do |tx, stream_id, proc|
  req = Ractor.recv
  proc.call(req, res)
  tx.send([res, stream_id], move: true)
  # → 終了
end
```

ループ型プールは実装可能：

```ruby
# プール案（biryani の設計変更が必要）
pool_ractor = Ractor.new(tx, proc) do |tx, proc|
  loop do
    stream_id, req = Ractor.recv   # stream_id もリクエストと一緒に受け取る
    break if req.nil?
    res = HTTP::Response.default
    proc.call(req, res)
    tx.send([res, stream_id], move: true)
  end
end
```

ただし biryani は現在 `stream_id` を Ractor 生成時の closure で渡しているため、
プール設計への移行はインターフェース変更を伴う。

## idle Ractor と SNT の関係

`Ractor.recv` でブロックした Ractor は [`rb_ractor_sched_wait`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1418)（`thread_sched.c:1418`）経由で
M:N スケジューラに入り、SNT（Shared Native Thread）を解放して休眠する。

→ プールした idle Ractors は SNT を占有しない。Ruby Ractor オブジェクトとして `vm->ractor.cnt` に
カウントされるが、スレッドのリソースは消費しない。

## thread_create_core ~10% への効果が限定的な理由

SNT 補充（[`native_thread_check_and_create_shared`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched_mn.c#L932)、`thread_sched_mn.c:932`）の発火条件：

```c
if (snt_cnt < schedulable_ractor_cnt &&
    snt_cnt < vm->ractor.sched.max_cpu) {
    // 新 SNT を作成（snt_cnt++）
}
```

**snt_cnt が減る原因**（[`thread_sched.c:1858-1881`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1858-L1881)）：

```c
native_thread_dedicated_inc():
    snt_cnt--;   // IO#read などのブロッキング I/O で dedicated SNT になるとき
    dnt_cnt++;
```

`IO#read` がブロッキングするたびに SNT が dedicated 化 → `snt_cnt` が `max_cpu` を下回る →
次の補充チェック（Ractor.new または timer）で pthread_create 発生。

`17aeb89200` では、dedicated から戻るときにプールが満杯ならその nt は retire する（[`native_thread_dedicated_dec`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1884-L1910)、`43793ca21a`）。
このため、余った SNT がプールにたまることはなくなった。ただし dedicated 化をきっかけに補充が走る構造は変わっていない。

**Stream Ractor プールの影響**：
- Ractor.new の呼び出しが減る → `native_thread_create_shared` の呼び出しが減る
- しかし SNT を減らすのは IO#read → プールしても IO#read は変わらない
- `schedulable_ractor_cnt` は常に `max_cpu` を大幅に超えるため、補充条件は IO#read が支配
- **結果**: thread_create_core ~10% はほぼ変わらない

## GC への効果（軽微）

リクエストごとに Ractor オブジェクト・Port オブジェクトが生成・廃棄されるが、
プール化によりこれらの短命オブジェクトが減り、GC ~8% がわずかに改善する可能性がある。
ただし定量的な効果は未測定。

## ruby/ruby の設計思想

M:N スケジューラの導入自体が「Ractor は使い捨てでも OS スレッドのコストを吸収する」という思想。
プールは application-level の最適化であり、ruby/ruby 側に変更を求める根拠は弱い。

## 次のアクション候補

- プールを実装して biryani でベンチマーク → GC への実際の効果を定量化
- GC ~8% の内訳調査（Ractor オブジェクトが占める割合）→ 新しい Q として登録

## 関連ページ

- [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md)
- [internals/biryani-ractor-architecture](../internals/biryani-ractor-architecture.md)
- [findings/flamegraph-c25-m50-vs-baseline](flamegraph-c25-m50-vs-baseline.md)
