---
date: 2026-05-17
type: pr
status: クローズ（誤分析）
---

# `rb_ractor_sched_wakeup`: broadcast → signal への変更

## 問題・提案

`ractor_sync.c` の `rb_ractor_sched_wakeup` は `pthread_cond_broadcast` を使っているが、
渡された `th` 引数を無視している。Ruby では 1 Ractor = 1 OS スレッドなので、
`broadcast`（全ウェイターを起こす）ではなく `signal`（1 ウェイターを起こす）で十分かつ意味的に正確。

```c
// 現在 (ractor_sync.c:963-968)
static void
rb_ractor_sched_wakeup(rb_ractor_t *r, rb_thread_t *th)
{
    // ractor lock is acquired
    rb_native_cond_broadcast(&r->sync.wakeup_cond);  // th 未使用
}

// 提案
static void
rb_ractor_sched_wakeup(rb_ractor_t *r, rb_thread_t *th)
{
    // ractor lock is acquired
    rb_native_cond_signal(&r->sync.wakeup_cond);
}
```

## 根拠

### コードレベルの根拠

1. **`th` 引数が未使用**: 関数シグネチャは `rb_thread_t *th` を受け取るが本体で一切使わない。
   呼び出し元 (`ractor_wakeup_all` L.944, `ubf_ractor_wait` L.974) は特定のスレッドを渡している。

2. **`rb_native_cond_signal` は既存 API**: `thread_pthread.c` の L.205 で定義済み。
   L.778, L.1314, L.1532, L.2507 で実際に使われている。

3. **セマンティクスの整合性**: 起こしたいスレッド (`th`) が分かっているのに全員に broadcast するのは過剰。

### パフォーマンスの根拠

- `-c25 -m50` FlameGraph: `futex` 系が CPU の ~11%（[findings/flamegraph-c25-m50-vs-baseline](../findings/flamegraph-c25-m50-vs-baseline.md)）
- `pthread_cond_broadcast` は Linux NPTL では `FUTEX_REQUEUE` を使い、mutex 待ちキューへ全ウェイターを移動する
- `pthread_cond_signal` は `FUTEX_WAKE 1` のみ — 実行コストが軽い
- biryani ベンチマーク: 10,000 req × ~1 wakeup/req ≒ 10,000 回の broadcast → signal 変換効果

## 変更量

1 行変更（`broadcast` → `signal`）。影響範囲は `rb_ractor_sched_wakeup` の呼び出し元 2 箇所:
- `ractor_wakeup_all` (L.944): 全ウェイターを起こす — N=1 なので signal で同等
- `ubf_ractor_wait` (L.974): 1 ウェイターのみを起こす — signal がより適切

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| [`ractor_sync.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/ractor_sync.c#L936-L939) | 936-939 | `rb_ractor_sched_wakeup` 本体 |
| [`ractor_sync.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/ractor_sync.c#L944-L970) | 944-970 | `ractor_wakeup_all`（呼び出し元） |
| [`ractor_sync.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/ractor_sync.c#L974-L1003) | 974-1003 | `ubf_ractor_wait`（呼び出し元） |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L205-L213) | 205-213 | `rb_native_cond_signal` 定義 |

詳細分析: [internals/ractor-sync-wakeup](../internals/ractor-sync-wakeup.md)

## クローズ理由（2026-05-17 追記）

**前提が誤っていた。**

`rb_ractor_sched_wakeup` の `pthread_cond_broadcast` は `#ifdef RUBY_THREAD_PTHREAD_H ... #else // win32` の **Win32 ブロック内**にある。Linux（pthread）ではこのコードパスは一切走らない。

pthread 版の `rb_ractor_sched_wakeup` は `thread_pthread.c:1428` に定義され、`r_th` 引数を正しく使って M:N スケジューラ経由で特定スレッドを起こす：

```
rb_ractor_sched_wakeup(r, r_th)           # thread_pthread.c:1428
  └─ thread_sched_to_ready_common(sched, r_th, ...)   # L.802
       └─ thread_sched_wakeup_running_thread(sched, next_th, ...) # L.769
            └─ rb_native_cond_signal(&next_th->nt->cond.readyq)   # すでに signal!
```

- `th` 引数は既に使われている（Win32 版のみ未使用）
- すでに `signal`（broadcast ではない）
- per-Ractor ではなく per-SNT（Shared Native Thread）の条件変数

FlameGraph の futex ~11% の真因は Ractor send ではなく、ブロッキング I/O による dedicated SNT の `cond_signal` / `cond_wait`。→ [findings/futex-mn-scheduler-dedicated-nt](../findings/futex-mn-scheduler-dedicated-nt.md)

## 関連する ruby/ruby のコード（正確な版）

| ファイル | 行 | 内容 |
|----------|---|------|
| [`ractor_sync.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/ractor_sync.c#L889-L940) | 889-940 | `#else // win32` ブロック（broadcast はここ） |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1428-L1443) | 1366-1380 | pthread 版 `rb_ractor_sched_wakeup`（th を使う） |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L769-L798) | 769-798 | `thread_sched_wakeup_running_thread`（signal） |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L875-L900) | 875-900 | `thread_sched_wait_running_turn`（cond_wait 側） |
