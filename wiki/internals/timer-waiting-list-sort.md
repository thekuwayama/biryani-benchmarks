---
date: 2026-05-27
tags: [internals, finding]
---

# `timer_th.waiting` のソート挿入 — O(n) の TODO

## サマリー

`timer_thread_register_waiting`（[`thread_pthread_mn.c:833`](https://github.com/ruby/ruby/blob/v4.0.2/thread_pthread_mn.c#L833)）は、
タイムアウト付き待機エントリをソート済みリストに O(n) で挿入する。
ko1 自身が `// TODO: O(n)` とコメントを残している。
**ただし biryani のワークロードはこのパスを通らない**ため、biryani での実測根拠づけは不可能。

## 挿入パスの分岐

[`timer_thread_register_waiting`](https://github.com/ruby/ruby/blob/v4.0.2/thread_pthread_mn.c#L695)
は `timer_th.waiting` リストへの挿入を 2 通りに分ける：

```c
if (abs == 0) { // no timeout
    // O(1)
    ccan_list_add_tail(&timer_th.waiting, &th->sched.waiting_reason.node);
}
else {
    // insert th to sorted list (TODO: O(n))
    ccan_list_for_each(&timer_th.waiting, w, node) { ... }
    // ソート済みの正しい位置を線形探索して挿入
}
```

`abs` は `rel`（相対タイムアウト）から計算される絶対時刻。`rel == NULL` なら `abs == 0` → O(1)。

## 呼び出し元と biryani との関係

`thread_sched_wait_events` を通じてこのパスに到達するのは：

| 呼び出し元 | `rel` | パス |
|-----------|-------|------|
| `IO#read`（タイムアウトなし） | `NULL` | **O(1)** |
| `IO#write`（タイムアウトなし） | `NULL` | **O(1)** |
| `Ractor.select` | fd=-1、`NULL` | **O(1)** |
| `Thread.sleep(n)` | `>0` | **O(n)** |
| `IO#wait(fd, events, timeout)` | `>0` | **O(n)** |

biryani が多用する `IO#read` / `IO#write` は `timeout=NULL` で呼ばれるため、
`thread_io_wait_events`（[`thread.c:1902`](https://github.com/ruby/ruby/blob/v4.0.2/thread.c#L1902)）
内で `prel = NULL` になり、O(1) パスを通る。

`SNT_KEEP_SECONDS` のアイドル待機は [`ractor_sched_deq`](https://github.com/ruby/ruby/blob/v4.0.2/thread_pthread.c#L1286-L1304)
内で `native_cond_timedwait` を直接呼ぶため、`timer_th.waiting` には一切入らない。

## O(n) が問題になるシナリオ

- 多数のスレッドが **異なるタイムアウトで同時に待機**するアプリ
  （例: `Thread.new { sleep(rand(10)) }` を大量生成）
- `IO#wait` に timeout を指定してポーリングするパターン

このようなアプリでは、n が大きくなると挿入のたびにリスト全体をスキャンしコストが増大する。

## 改善の方向性

ソート済みリストを priority heap（min-heap）で置き換えることで O(log n) になる。
ただし Ruby の内部実装は `ccan_list`（双方向リンクリスト）を広く使っており、
汎用 heap 実装の追加か、特定用途の heap の追加が必要。

## コントリビュートとしての評価

| 観点 | 評価 |
|------|------|
| TODO の明示 | `thread_pthread_mn.c:833` に ko1 自身が記載 |
| 実装難易度 | 中（priority heap 実装が必要） |
| biryani での実測検証 | **不可能**（O(n) パスが呼ばれない） |
| 一般的なワークロードへの影響 | `Thread.sleep` / `IO#wait` with timeout を多用するアプリに有効 |
| 根拠データの取得しやすさ | 難しい（専用ベンチが必要） |

biryani ベンチマーク由来の数値で根拠を示せないため、
SNT 補充系の候補（`SNT_KEEP_SECONDS`、`MINIMUM_SNT`）より優先度は低い。

## 関連ページ

- [source-reading-guide](../source-reading-guide.md) — ソースコード読み方ガイド
- [internals/ractor-mn-snt-lifecycle](ractor-mn-snt-lifecycle.md)
- [contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md)
- [findings/snt-keep-seconds-disabled](../findings/snt-keep-seconds-disabled.md)
