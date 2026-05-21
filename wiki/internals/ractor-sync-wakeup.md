---
date: 2026-05-17
tags: [internals]
---

# Ractor 同期：wakeup メカニズムの実装（ractor_sync.c）

`ractor_sync.c` の wakeup パスを精査した。`pthread_cond_broadcast` の使われ方に
コード品質と最適化の観点から注目すべき点が3つある。

## プラットフォーム分岐（重要）

`ractor_sync.c` の wakeup 実装は **Win32 と pthreads で完全に別コード**。

```c
// ractor_sync.c:913
#ifdef RUBY_THREAD_PTHREAD_H
// pthread 版: rb_ractor_sched_wakeup は thread_pthread.c で定義
#else // win32
static void
rb_ractor_sched_wakeup(rb_ractor_t *r, rb_thread_t *th)
{
    rb_native_cond_broadcast(&r->sync.wakeup_cond);  // th は未使用！
}
#endif
```

Linux（Lima VM のベンチマーク環境）では **`#else // win32` ブロックは走らない**。

## Linux (pthread) の実際のコールチェーン

```
Ractor::Port#send
  └─ ractor_send0
       └─ ractor_send_basket          # lock → enqueue → unlock
            └─ ractor_wakeup_all      # ractor_sync.c:972
                 └─ rb_ractor_sched_wakeup(r, waiter->th)  # thread_pthread.c:1366
                      └─ thread_sched_to_ready_common(sched, r_th, ...)  # L.795
                           └─ thread_sched_wakeup_running_thread(sched, r_th, ...)  # L.762
                                └─ rb_native_cond_signal(&r_th->nt->cond.readyq)  # per-SNT signal!
```

重要なポイント：
- **`th` 引数は pthread 版では正しく使われている**（waiter のスレッドを直接指定）
- **すでに `signal`**（broadcast ではない）
- **per-Ractor ではなく per-SNT**（Shared Native Thread）の条件変数 `th->nt->cond.readyq`

`ractor_send_basket` の enqueue 部分（参考）：

```c
// ractor_sync.c:1185-1200（抜粋）
RACTOR_LOCK(rp->r);
ractor_queue_enq(rp->r, rp->r->sync.recv_queue, b);
RACTOR_UNLOCK(rp->r);

if (!closed) {
    ractor_wakeup_all(rp->r, wakeup_by_send);  // 必ずロック外で呼ぶ
}
```

## Win32 版の問題点（Linux には無関係）

Win32 ブロック内の `rb_ractor_sched_wakeup` では `th` 引数が無視されている。
これは Win32 のみに影響し、Linux ベンチマーク環境には関係しない。

→ [contributions/cond-signal-vs-broadcast](../contributions/cond-signal-vs-broadcast.md)（クローズ済み）

## 発見 B: `ractor_wakeup_all` が N 人のウェイターに N 回 wakeup を呼ぶ

```c
// 972-998行（プラットフォーム共通）
static bool
ractor_wakeup_all(rb_ractor_t *r, enum ractor_wakeup_status wakeup_status)
{
    RACTOR_LOCK(r);
    while (1) {
        struct ractor_waiter *waiter = ccan_list_pop(&r->sync.waiters, ...);
        if (waiter) {
            waiter->wakeup_status = wakeup_status;
            rb_ractor_sched_wakeup(r, waiter->th);  // ← ループ内
            wakeup_p = true;
        }
        else { break; }
    }
    RACTOR_UNLOCK(r);
    return wakeup_p;
}
```

現実には 1 Ractor = 1 スレッド（M:N 下でも Ractor につき 1 Ruby スレッド）なので N ≤ 1。実害なし。

## 発見 C: `Ractor.select` が毎 wakeup で全ポートをポーリング

```c
// ractor_selector__wait（1420-1440行）
while (1) {
    st_foreach(s->ports, ractor_selector_wait_i, ...);  // 全ポートを走査
    if (data.found) return result;
    ractor_wait_receive(ec, cr);  // 次のメッセージまで眠る
}
```

- biryani `-c25 -m50` で 1 接続あたり最大 52 ポートを監視
- wakeup のたびに 52 port の per-port queue を poll する
- 送信側は「どのポートに送ったか」を知っている（`b->port_id`）が、wakeup 信号に含めない

仮に「wakeup 時にポート ID を渡す」設計にすれば、そのポートを優先チェックできる。
ただし実測では `Ractor.select` の 33.5% wall time のほとんどは睡眠（futex_wait）であり、
ポーリング自体のコストは小さい可能性が高い。

## wakeup_cond の設計

```c
// r->sync 構造体（概念図）
struct {
    rb_nativethread_lock_t  lock;       // ractor 操作全般を保護
    rb_nativethread_cond_t  wakeup_cond;// recv 待機用
    struct ccan_list_head   waiters;    // ractor_waiter のリスト
    struct ractor_queue    *recv_queue; // 共通着信キュー
} sync;
```

`wakeup_cond` は受信側の lock と対になっている。
1 Ractor = 1 スレッドなので `waiters` は常に 0 か 1 エントリ。

## 関連ページ

- [internals/ractor-port-implementation](ractor-port-implementation.md)
- [findings/rperf-wall-vs-perf-cpu](../findings/rperf-wall-vs-perf-cpu.md)
- [questions/README](../questions/README.md)
- [contributions/cond-signal-vs-broadcast](../contributions/cond-signal-vs-broadcast.md)
