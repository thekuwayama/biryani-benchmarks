---
date: 2026-05-23
tags: [internals]
---

# `Ractor.select` の C 実装

`Ractor.select(*ports)` がどのようにブロック・ウェイクアップするかを解説する。

## 呼び出しチェーン

```
Ractor.select(@sock, @streams_ctx.tx)           # ractor.rb:308
  └─ __builtin_ractor_select_internal(ports)    # ractor.rb:328
       └─ ractor_select_internal()              # ractor_sync.c:1467
            └─ ractor_selector__wait()          # ractor_sync.c:1420
```

## `ractor_selector__wait` の実装（ractor_sync.c:1420）

```c
while (1) {
    // 全ポートを非ブロッキングでポール
    st_foreach(s->ports, ractor_selector_wait_i, (st_data_t)&data);

    if (data.found) {
        return rb_ary_new_from_args(2, data.rpv, data.v);  // 即座に返す
    }

    // どのポートにもメッセージがなければブロック
    ractor_wait_receive(ec, cr);
}
```

各 wakeup のたびに全ポートを `ractor_try_receive`（キューのノンブロッキングデキュー）でスキャンする。
ポート数 N の場合 O(N) のスキャンコストがかかる。biryani は N=2 なので無視できる。

## ブロック機構（Linux/pthread）

```
ractor_wait_receive (ractor_sync.c:1107)
  └─ ractor_wait (ractor_sync.c:1032)
       └─ rb_ractor_sched_wait (thread_pthread.c:1330)  ← Linux版
            ├─ thread_sched_wakeup_next_thread()  ← 次の実行可能スレッドに譲る
            └─ thread_sched_wait_running_turn()   ← M:N スケジューラで休眠
```

Win32 版は `ractor_sync.c:917` の `#else // win32` ブロックに `rb_native_cond_wait` ベースの実装がある。
Linux 版は `thread_pthread.c` に定義され、M:N スケジューラ経由でスレッドを `THREAD_STOPPED_FOREVER` 状態にする。

## ウェイクアップ機構

送信側（`ractor_send_basket` など）が `ractor_wakeup_all` を呼ぶ：

```
ractor_wakeup_all (ractor_sync.c:972)
  └─ rb_ractor_sched_wakeup (thread_pthread.c:1366)
       └─ thread_sched_to_ready_common()  ← STOPPED_FOREVER → runnable
```

waiter が 1 人（biryani の select_loop は単一スレッド）なら wakeup は 1 回のみ発生する。

## Win32 版との違い

| 項目 | Linux (pthread) | Win32 |
|------|----------------|-------|
| 待機関数 | `thread_sched_wait_running_turn` | `rb_native_cond_wait` |
| wakeup関数 | `thread_sched_to_ready_common` | `rb_native_cond_broadcast` |
| 定義場所 | `thread_pthread.c` | `ractor_sync.c:#else` |

## 関連ページ

- [source-reading-guide](../source-reading-guide.md) — ソースコード読み方ガイド
- [findings/ractor-select-wait-breakdown](../findings/ractor-select-wait-breakdown.md)
- [internals/ractor-sync-wakeup](ractor-sync-wakeup.md)
- [internals/ractor-mn-snt-lifecycle](ractor-mn-snt-lifecycle.md)
