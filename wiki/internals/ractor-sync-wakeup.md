---
date: 2026-05-17
tags: [internals]
---

# Ractor 同期：wakeup メカニズムの実装（ractor_sync.c）

`ractor_sync.c` の wakeup パスを精査した。`pthread_cond_broadcast` の使われ方に
コード品質と最適化の観点から注目すべき点が3つある。

## コールチェーン（send → wakeup）

```
Ractor::Port#send
  └─ ractor_send0
       └─ ractor_send_basket          # lock → enqueue → unlock
            └─ ractor_wakeup_all      # 1200行
                 └─ rb_ractor_sched_wakeup   # 964行
                      └─ rb_native_cond_broadcast(r->sync.wakeup_cond)
```

`ractor_send_basket` は:
1. Receiver の lock を取り、recv_queue に basket を積み、unlock
2. `ractor_wakeup_all` を呼んで Receiver を起こす

```c
// 1185-1200行（抜粋）
RACTOR_LOCK(rp->r);
ractor_queue_enq(rp->r, rp->r->sync.recv_queue, b);
RACTOR_UNLOCK(rp->r);

if (!closed) {
    ractor_wakeup_all(rp->r, wakeup_by_send);  // 必ずロック外で呼ぶ
}
```

## 発見 A: `th` 引数が完全に無視されている

```c
// 963-968行
static void
rb_ractor_sched_wakeup(rb_ractor_t *r, rb_thread_t *th)
{
    // ractor lock is acquired
    rb_native_cond_broadcast(&r->sync.wakeup_cond);  // th は未使用
}
```

- `th` は呼び出し元から渡されるが関数内で一切使われない
- `rb_native_cond_signal` はコードベースに存在し `thread_pthread.c` の 771・1253・1469・2435 行で使われている
- 1 Ractor = 1 OS スレッド なので `wakeup_cond` を待っているスレッドは常に ≤1
- `broadcast` は「全ウェイターを起こす」、`signal` は「ウェイターを1つ起こす」

`signal` への変更は意味的により正確で、`th` 引数の存在とも整合する。

## 発見 B: `ractor_wakeup_all` が N 人のウェイターに N 回 broadcast

```c
// 972-998行
static bool
ractor_wakeup_all(rb_ractor_t *r, enum ractor_wakeup_status wakeup_status)
{
    RACTOR_LOCK(r);
    while (1) {
        struct ractor_waiter *waiter = ccan_list_pop(&r->sync.waiters, ...);
        if (waiter) {
            waiter->wakeup_status = wakeup_status;
            rb_ractor_sched_wakeup(r, waiter->th);  // ← ループ内で broadcast
            wakeup_p = true;
        }
        else { break; }
    }
    RACTOR_UNLOCK(r);
    return wakeup_p;
}
```

N 人のウェイターがいると broadcast が N 回呼ばれる。1 回でも全員起きる。
ただし現実には 1 Ractor = 1 スレッドなので N ≤ 1 であり実害はない。

構造的な改善案:

```c
// 全ステータスをセットしてから 1 回だけ broadcast
bool wakeup_p = false;
RACTOR_LOCK(r);
while (1) {
    waiter = ccan_list_pop(...)
    if (waiter) { waiter->wakeup_status = wakeup_status; wakeup_p = true; }
    else break;
}
if (wakeup_p) rb_native_cond_broadcast(&r->sync.wakeup_cond);
RACTOR_UNLOCK(r);
```

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

- [[internals/ractor-port-implementation]]
- [[findings/rperf-wall-vs-perf-cpu]]
- [[questions/README]]
- [[contributions/cond-signal-vs-broadcast]]
