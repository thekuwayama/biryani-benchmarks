---
date: 2026-05-17
tags: [finding]
---

# FlameGraph 分析 — ベースラインの CPU プロファイル

ベースラインシナリオ（-n10000 -c50 -m100 -t10）に対して perf + FlameGraph でプロファイルを取った結果。

## 主要な CPU 消費内訳

| 関数 | CPU 占有率 | カテゴリ |
|------|-----------|---------|
| `[unknown]` | 28.21% | 未解決シンボル |
| `[libc.so.6]` | ~11% | libc（未解決） |
| `thread_create_core` | 7.14% | Ractor 生成 |
| `native_thread_create` / `native_thread_create_shared` | 6.79% | Ractor 生成 |
| `nt_alloc_stack` | 4.64% | スレッドスタック確保 |
| `vm_exec_core` | 計 ~10% | Ruby VM インタープリタ |
| `invoke_syscall` / `el0_svc` / `do_futex` | 計 ~16% | Ractor 間同期（futex） |
| `thread_mark` / `rb_gc_mark_children` / `gc_sweep_step` | 計 ~11% | GC |

## 分析

### Ractor 生成コスト（~12%）

`thread_create_core` + `nt_alloc_stack` 合計で約 12% の CPU 時間を消費している。biryani の実装では接続ごと（またはリクエストごと）に Ractor を生成している可能性があり、そのスレッド生成オーバーヘッドがプロファイルに現れている。Ractor はユーザーレベルのグリーンスレッドではなく OS スレッドにマッピングされているため、生成コストが重い。

### futex による同期オーバーヘッド（~16%）

`do_futex` / `futex_wake` / `wake_up_q` などが合計で約 16% を占める。これは Ractor 間の同期・スケジューリングに使われる Linux の futex システムコールであり、Ractor が共有リソースへのアクセスやメッセージパッシングで待機していることを示す。

### GC（~11%）

`thread_mark` / `rb_gc_mark_children` / `gc_sweep_step` が合計で約 11%。GET リクエストにボディなしのシンプルなシナリオでもこの程度の GC 圧力がある。POST ボディを追加すればさらに増加すると予想される。

### 未解決シンボル（28%）

`[unknown]` が 28% と多い。Ruby バイナリのデバッグシンボルがないため、この部分のコールスタックが解決できていない。`rbenv install --keep` でビルド済みのソースツリーを使うか、デバッグビルドの Ruby を使うと解像度が向上する。

## 次に調べると良いこと

1. Ractor プールを実装して生成コストを削減し、スループットとレイテンシへの影響を測る
2. デバッグシンボル付きの Ruby でプロファイルして `[unknown]` を解決する
3. POST ボディ付きのシナリオで GC 圧力がどう増加するか測定する

## 関連ページ

- [[scenarios/baseline-default]]
- [[findings/latency-stream-multiplexing]]
- [[overview]]
