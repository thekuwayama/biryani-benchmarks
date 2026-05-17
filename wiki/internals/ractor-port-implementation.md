---
date: 2026-05-17
tags: [internals]
---

# `Ractor::Port` の実装（ruby/ruby v4.0.2）

`raw/ruby-src/ractor_sync.c` および `ractor.c` を読んで調査。

## データ構造

```c
struct ractor_port {
    rb_ractor_t *r;   // このポートを所有する Ractor
    uint64_t id_;     // Ractor 内で一意なポート ID
};
```

Port は軽量なハンドル。メッセージを保持せず、キューは Ractor 側が持つ：

```c
// Ractor の同期状態（r->sync.*）
rb_native_mutex_t   lock;           // Ractor ロック（pthread mutex）
struct ractor_queue *recv_queue;    // 全 Port への着信を受け取る共通キュー
st_table            *ports;         // port_id → ractor_queue のハッシュ
rb_native_cond_t    wakeup_cond;   // 待機スレッドを起こす条件変数（Win32のみ）
```

Linux/macOS では `wakeup_cond` の代わりに `rb_nogvl` + pthreads スケジューラを使う。

## メッセージ送信の流れ（`ractor_send_basket`）

```c
RACTOR_LOCK(rp->r);                          // 1. pthread_mutex_lock
  ractor_queue_enq(rp->r, recv_queue, b);    // 2. 共通キューに enqueue
RACTOR_UNLOCK(rp->r);                        // 3. pthread_mutex_unlock

ractor_wakeup_all(rp->r, wakeup_by_send);   // 4. 待機中の全スレッドを起こす
  → RACTOR_LOCK
  → rb_ractor_sched_wakeup()
      → pthread_cond_broadcast()            // ← futex_wake syscall
  → RACTOR_UNLOCK
```

送信は **ノンブロッキング**。送った後すぐ返る。ただし wakeup_all が必ずカーネルに降りる。

## メッセージ受信の流れ（`ractor_receive`）

```c
while (1) {
    v = ractor_try_receive(ec, cr, rp);  // per-port キューから dequeue 試行

    if (v != Qundef) return v;           // メッセージがあれば即リターン
    else {
        ractor_wait_receive(ec, cr);     // なければ待機
            RACTOR_LOCK_SELF(cr);
            if (recv_queue が空) {
                ractor_wait(ec, cr);
                    // waiters リストに追加
                    rb_ractor_sched_wait()
                        → rb_nogvl(ractor_wait_no_gvl, ...)
                            → pthread_cond_wait()  // ← futex(FUTEX_WAIT)
            }
            RACTOR_UNLOCK_SELF(cr);
        // 起床後: recv_queue → per-port キューへ振り分け
    }
}
```

## 二段キュー設計（recv_queue + per-port queues）

```
送信者               受信 Ractor
  send()
    ↓
  recv_queue ─[起床]→  ractor_wait_receive()
                           ↓
                       recv_queue → per-port キューへ振り分け
                           ↓
                       ractor_try_receive() で該当 port を dequeue
```

**この設計の意図**:
- 複数の Port があっても Ractor を起こすのは1回でよい（`recv_queue` が共通バッファ）
- `Ractor.select` が複数 Port を待つ際に、起床後に振り分ければよい
- Port ごとに条件変数を持つ必要がない → 構造がシンプル

## FlameGraph の `do_futex` 16% との対応

| FlameGraph の関数 | 対応するコード |
|-------------------|---------------|
| `do_futex` / `futex_wake` | `ractor_wakeup_all` → `pthread_cond_broadcast` |
| `el0_svc` / `invoke_syscall` | futex システムコールのカーネルエントリ（ARM64） |
| `wake_up_q` / `try_to_wake_up` | futex によるスレッドのスケジューリング復帰 |

biryani のベースライン（-c50 -m100）では 5,000 の Stream Ractor が `@tx.send()` を呼ぶ。
**1送信 = 1 `pthread_cond_broadcast` = 1 futex システムコール**。これが 16% の原因。

## パフォーマンス上の含意

- futex のオーバーヘッドはメッセージ数に比例する（リクエスト数 × Ractor メッセージ数）
- ストリーム数（`-m`）を下げると Stream Ractor の数が減り、futex 呼び出しも減る
- Ractor プールを使っても、メッセージ送信のたびに futex は発生する — 削減するには Ractor 間の通信回数自体を減らす必要がある
- `RACTOR_LOCK` / `RACTOR_UNLOCK`（pthread mutex）も毎送信で呼ばれるが、FlameGraph には `futex_wake` の形で現れている

## 関連ページ

- [[internals/biryani-ractor-architecture]]
- [[findings/flamegraph-baseline-cpu-profile]]
- [[findings/latency-stream-multiplexing]]
