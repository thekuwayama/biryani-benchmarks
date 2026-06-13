---
date: 2026-06-13
type: pr
status: 調査中
---

# SNT タイムアウト終了時の nt クリーンアップ修正と SNT_KEEP_SECONDS の有効化

## 問題・提案

M:N スケジューラの SNT（Shared Native Thread）プールは**一方向にのみ増加**し、
アイドル状態になっても縮小しない。`SNT_KEEP_SECONDS` という縮小メカニズムはすでに
実装されているが、`SNT_KEEP_SECONDS = 0` でハードコードされており無効化されている。

無効化の根本原因は `SNT_KEEP_SECONDS > 0` 時に発生する**メモリリーク**であることが
ソース調査で判明した。SNT がタイムアウト終了する際に `nt` 構造体が解放されない。

## ソースコード上の根拠

### 現状: nt 構造体が解放されない

SNT 作成時（[`native_thread_alloc`（:2244）](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2244)）に確保されるリソース:

| リソース | 確保方法 | 解放場所 |
|--------|--------|--------|
| `nt`（rb_native_thread 構造体） | `ZALLOC` | **なし** |
| `nt->nt_context`（コルーチンコンテキスト） | `ruby_xmalloc` | **なし** |
| `nt->altstack`（シグナル代替スタック） | `rb_allocate_sigaltstack` | **なし** |

SNT タイムアウト終了パス（[`nt_start`（:2366）](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2366)）:

```c
else {
    // timeout -> deleted.
    break;   // ← nt/nt_context/altstack は未解放のまま return NULL
}
```

### 既存の TODO

[`rb_threadptr_sched_free`（:2407）](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2407) の SNT（非 dedicated）パスに ko1 が残した TODO:

```c
else {
    nt_free_stack(th->sched.context_stack);
    // TODO: how to free nt and nt->altstack?
}
```

### 正しいクリーンアップ手順

[`native_thread_destroy_atfork`（:1880）](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1880) と `native_thread_destroy`（:1901）がすでに正しい解放順を実装している:

```c
rb_native_cond_destroy(&nt->cond.readyq);  // 条件変数の破棄（native_thread_destroy）
RB_ALTSTACK_FREE(nt->altstack);            // altstack 解放
SIZED_FREE(nt->nt_context);               // nt_context 解放
SIZED_FREE(nt);                           // nt 構造体解放
```

## 変更案

### Step 1: nt_start にクリーンアップを追加

```c
// thread_pthread.c — nt_start() の timeout break 前
else {
    // timeout -> deleted.
    // nt/nt_context/altstack を解放してから終了
    native_thread_destroy(nt);
    SIZED_FREE(nt);
    break;
}
```

`native_thread_destroy` は内部で `rb_native_cond_destroy` + `native_thread_destroy_atfork`
（altstack/nt_context/nt の解放）を呼ぶ。

**確認が必要な点**: `nt_start` 内で `ruby_xfree` / `SIZED_FREE` を呼ぶのに
ロック・GVL などの制約がないか確認。SNT は GVL を持たない状態でアイドルしているため
問題ないと考えられるが、要検証。

### Step 2: SNT_KEEP_SECONDS のデフォルト値を設定

```c
// thread_pthread.c
#ifndef SNT_KEEP_SECONDS
#define SNT_KEEP_SECONDS 60  // アイドル SNT を 60 秒で解放
#endif
```

適切な値はワークロードに依存する。biryani のような常時 I/O ワークロードでは
実際に idle になる SNT がほとんどないため、高い値（60〜300 秒）でも問題ない。

### Step 3（オプション）: rb_threadptr_sched_free の TODO を解消

TODO コメントの箇所（`!malloc_stack` パス）でも `native_thread_destroy` + `SIZED_FREE` を
呼ぶことで TODO を解消できるが、このパスでは `th->nt` が NULL になっている可能性がある
（`co_start` で `native_thread_assign(NULL, th)` が呼ばれるため）。要確認。

## 期待される効果

`SNT_KEEP_SECONDS > 0` で SNT が縮小するようになると:

- ピーク負荷後に過剰 SNT が解放され、常駐メモリが減少
- コンテキストスイッチ圧が低減される可能性（biryani の `thread_create_core ~10%` の副次改善）
- `max_cpu`（成長上限）と `SNT_KEEP_SECONDS`（縮小速度）が両方機能する設計本来の姿になる

実測はまだ行っていない。修正後に `SNT_KEEP_SECONDS = 5` でビルドして FlameGraph を比較すること。

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|--------|-----|------|
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1322-L1329) | 1322-1329 | `SNT_KEEP_SECONDS`・`MINIMUM_SNT` の定義 |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1347-L1365) | 1347-1365 | `ractor_sched_deq` のタイムアウト分岐 |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2366-L2368) | 2366-2368 | `nt_start` のタイムアウト終了パス（クリーンアップなし） |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2407-L2418) | 2407-2418 | `rb_threadptr_sched_free`（TODO あり） |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1880-L1898) | 1880-1898 | `native_thread_destroy_atfork`（正しいクリーンアップの参考） |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1901-L1912) | 1901-1912 | `native_thread_destroy` |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2244-L2258) | 2244-2258 | `native_thread_alloc`（確保側） |

## 次のステップ

1. `nt_start` のタイムアウトパスに `native_thread_destroy(nt)` + `SIZED_FREE(nt)` を追加してビルド
2. Valgrind またはアドレスサニタイザで解放漏れが消えることを確認
3. `SNT_KEEP_SECONDS = 5` でビルドして biryani を長時間稼働させ `snt_cnt` の推移を確認
4. FlameGraph で `thread_create_core` の変化を計測
5. ruby/ruby に PR 提出（クリーンアップ修正と SNT_KEEP_SECONDS の有効化を別 PR にするか検討）

## 関連ページ

- [findings/snt-keep-seconds-disabled](../findings/snt-keep-seconds-disabled.md) — SNT_KEEP_SECONDS の仕組みと現状
- [internals/mn-snt-pool-growth-shrink](../internals/mn-snt-pool-growth-shrink.md) — max_cpu と SNT_KEEP_SECONDS の役割
- [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md) — SNT ライフサイクル全体
- [contributions/snt-replenishment-overhead](snt-replenishment-overhead.md) — SNT 補充コストの削減（関連候補）
