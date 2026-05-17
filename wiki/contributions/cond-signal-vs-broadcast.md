---
date: 2026-05-17
type: pr
status: 候補
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
   呼び出し元 (`ractor_wakeup_all` L.988, `ubf_ractor_wait` L.1023) は特定のスレッドを渡している。

2. **`rb_native_cond_signal` は既存 API**: `thread_pthread.c` の L.205 で定義済み。
   L.771, L.1253, L.1469, L.2435 で実際に使われている。

3. **セマンティクスの整合性**: 起こしたいスレッド (`th`) が分かっているのに全員に broadcast するのは過剰。

### パフォーマンスの根拠

- `-c25 -m50` FlameGraph: `futex` 系が CPU の ~11%（`[[findings/flamegraph-c25-m50-vs-baseline]]`）
- `pthread_cond_broadcast` は Linux NPTL では `FUTEX_REQUEUE` を使い、mutex 待ちキューへ全ウェイターを移動する
- `pthread_cond_signal` は `FUTEX_WAKE 1` のみ — 実行コストが軽い
- biryani ベンチマーク: 10,000 req × ~1 wakeup/req ≒ 10,000 回の broadcast → signal 変換効果

## 変更量

1 行変更（`broadcast` → `signal`）。影響範囲は `rb_ractor_sched_wakeup` の呼び出し元 2 箇所:
- `ractor_wakeup_all` (L.988): 全ウェイターを起こす — N=1 なので signal で同等
- `ubf_ractor_wait` (L.1023): 1 ウェイターのみを起こす — signal がより適切

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| `raw/ruby-src/ractor_sync.c` | 963-968 | `rb_ractor_sched_wakeup` 本体 |
| `raw/ruby-src/ractor_sync.c` | 984-998 | `ractor_wakeup_all`（呼び出し元） |
| `raw/ruby-src/ractor_sync.c` | 1013-1028 | `ubf_ractor_wait`（呼び出し元） |
| `raw/ruby-src/thread_pthread.c` | 205-213 | `rb_native_cond_signal` 定義 |

詳細分析: [[internals/ractor-sync-wakeup]]

## 次のステップ

1. **実測**: ruby/ruby を patch して benchmark を比較する
   - 現在: `pthread_cond_broadcast`
   - 変更後: `pthread_cond_signal`
   - 指標: FlameGraph の futex 比率・h2load の req/s
2. **ruby-dev / GitHub Issue で事前確認**: 意図的に `broadcast` にしている理由があるか
   （例: GVL 解放中の spurious wakeup 対策など）
3. 問題なければ PR 作成

## 懸念点

- `broadcast` を意図的に使っている理由がある可能性（コメントなし）
- 将来的に 1 Ractor に複数スレッドを許す設計変更がある場合は `broadcast` が必要
- Win32 実装（`#else // win32` ブランチ L.917）では別の実装があるため確認が必要
