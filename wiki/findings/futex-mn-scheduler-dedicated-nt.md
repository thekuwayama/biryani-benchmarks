---
date: 2026-05-17
tags: [finding, internals]
---

# FlameGraph の futex ~11% の真因：M:N スケジューラの dedicated SNT

FlameGraph で futex 系が CPU の ~11% を占める理由を特定した。
Ractor send（`pthread_cond_broadcast`）ではなく、**ブロッキング I/O による dedicated SNT の `pthread_cond_signal` / `pthread_cond_wait`** が出所。

## コールチェーン

### wait 側（ブロッキング I/O に入るとき）

```
rb_ractor_sched_wait (thread_pthread.c:1330)
  └─ thread_sched_wakeup_next_thread (L.954)   # 次のスレッドに実行権を渡す
  └─ thread_sched_wait_running_turn (L.831)
       └─ [th_has_dedicated_nt が true のとき]
            rb_native_cond_wait(&th->nt->cond.readyq, &sched->lock_)  # ← futex_wait
```

### signal 側（I/O 完了 → 当該スレッドを再スケジュール）

```
rb_ractor_sched_wakeup (thread_pthread.c:1366)
  └─ thread_sched_to_ready_common (L.795)
       └─ thread_sched_wakeup_running_thread (L.762)
            └─ [th_has_dedicated_nt が true のとき]
                 rb_native_cond_signal(&next_th->nt->cond.readyq)  # ← futex_wake
```

## なぜ biryani で多発するか

biryani の I/O プロファイル（rperf wall time）：

| メソッド | wall time |
|---------|-----------|
| `IO#read` | 47.9% |
| `IO#write` | 14.6% |

`IO#read` はブロッキング I/O → Ruby スレッドは `rb_ractor_sched_wait` を呼び、dedicated SNT に切り替わる。
I/O が完了するたびに `rb_native_cond_signal` が発行される。

`-c25 -m50` で 1,300 Ractors、各接続が複数回の `IO#read` を行うため、大量の signal/wait サイクルが発生する。

## dedicated NT とは

M:N スケジューラでは通常 M Ruby スレッドが N SNT を共有するが、
**ブロッキング操作を行うスレッドは dedicated SNT（専用 OS スレッド）を取得する**。

```c
// thread_sched_to_waiting_common (thread_pthread.c:1003)
native_thread_dedicated_inc(th->vm, th->ractor, th->nt);
```

これにより `th_has_dedicated_nt(th)` が true になり、`cond.readyq` を使った
`pthread_cond_wait` / `signal` ペアでスリープ/ウェイクアップする。

## FlameGraph の futex ~11% との対応

| futex 操作 | 対応コード |
|-----------|----------|
| `futex_wait` | `rb_native_cond_wait(&th->nt->cond.readyq, ...)` |
| `futex_wake` / `futex_requeue` | `rb_native_cond_signal(&next_th->nt->cond.readyq)` |

これは **Ractor send とは無関係**。Ractor send の wakeup は `rb_native_cond_signal` だが、
その条件変数は `th->nt->cond.readyq`（dedicated SNT のスケジューラキュー）であり、
Ractor ごとの `sync.wakeup_cond` ではない（Win32 除く）。

## 関連ページ

- [[findings/rperf-wall-vs-perf-cpu]]
- [[internals/ractor-sync-wakeup]]
- [[internals/ractor-overview]]
- [[contributions/cond-signal-vs-broadcast]]
