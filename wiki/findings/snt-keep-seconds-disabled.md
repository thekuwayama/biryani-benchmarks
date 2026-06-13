---
date: 2026-05-24
tags: [finding, internals]
---

# `SNT_KEEP_SECONDS = 0` — SNT プールが実行時に縮小しない

## サマリー

M:N スケジューラの SNT（Shared Native Thread）プールには「アイドル SNT をタイムアウトで
終了させる」仕組み（`SNT_KEEP_SECONDS`）が既に実装されているが、デフォルト値 0 により
完全に無効化されている。結果として SNT プールは起動後に一方向に増加し、
ピーク負荷から回復しても過剰 SNT が残り続ける。

## `SNT_KEEP_SECONDS` の仕組み

```c
// thread_pthread.c:1261-1262
#ifndef SNT_KEEP_SECONDS
#define SNT_KEEP_SECONDS 0   // デフォルト: 無効
#endif
```

SNT が空の GRQ（Global Ractor Queue）で待つ際の動作：

```c
// thread_pthread.c:1286-1304 — ractor_sched_deq() 内
#if SNT_KEEP_SECONDS > 0
    rb_hrtime_t abs = rb_hrtime_add(rb_hrtime_now(), RB_HRTIME_PER_SEC * SNT_KEEP_SECONDS);
    if (native_cond_timedwait(&vm->ractor.sched.cond,
                              &vm->ractor.sched.lock, &abs) == ETIMEDOUT) {
        // タイムアウト → SNT 終了
        vm->ractor.sched.snt_cnt--;
        vm->ractor.sched.running_cnt--;
        break;
    }
#else
    // 現在の動作：永遠に待つ
    rb_native_cond_wait(&vm->ractor.sched.cond, &vm->ractor.sched.lock);
#endif
```

`SNT_KEEP_SECONDS > 0` のとき: アイドル SNT が N 秒待っても GRQ に仕事がなければ `snt_cnt--` して自身を終了させる。

`SNT_KEEP_SECONDS = 0`（現在）: アイドル SNT は GRQ に仕事が来るまで無限に待機する。プールは縮小しない。

## biryani で起きていること

biryani（-c25 -m50）では `IO#read` が wall time の 47.9% を占め、高頻度でブロッキング I/O が発生する。
その結果、以下のサイクルが繰り返される：

```
IO#read 開始
  → dedicated_inc: snt_cnt: 8 → 7
    → timer fire (~10ms): check_and_create → pthread_create  ← thread_create_core ~10%
      → snt_cnt: 7 → 8（新 SNT 追加）

IO#read 完了（数十〜数百μs 後）
  → dedicated_dec: snt_cnt: 8 → 9（過剰）

新 SNT が GRQ から仕事を取得 → snt_cnt は 9 のまま活動
（GRQ 常に非空のため idle にならない → タイムアウトしない → 永続化）
```

`SNT_KEEP_SECONDS = 0` では、過剰 SNT は GRQ に仕事がある限り idle にならず、
VM 終了まで生き続ける。biryani のような高 I/O ワークロードでは常に仕事があるため、
一度作られた excess SNT は消えない。

## `default_max_cpu` との関係

`SNT_KEEP_SECONDS` と `MINIMUM_SNT`（後述）は `default_max_cpu` と同じ commit に導入された：

| 定数 | 導入 commit | 著者 | 状態 |
|------|------------|------|------|
| `default_max_cpu = 8` | be1bbd5b7（2023-04-10） | ko1 | **提出済み** |
| `SNT_KEEP_SECONDS = 0` | be1bbd5b7（2023-04-10） | ko1 | 未解決 |
| `MINIMUM_SNT = 0` | be1bbd5b7（2023-04-10） | ko1 | 未解決（"for debug"） |

`max_cpu` がプールの**上限**（成長の制御）を担い、
`SNT_KEEP_SECONDS` がプールの**縮小速度**（アイドル時の解放）を担う設計意図が読み取れる。
この 2 つがセットで機能するはずが、片方だけ TODO のまま残っている。

## `MINIMUM_SNT = 0` について

```c
// thread_pthread.c:1265-1267
#ifndef MINIMUM_SNT
// make at least MINIMUM_SNT snts for debug.
#define MINIMUM_SNT 0
#endif
```

補充条件（`thread_pthread_mn.c:421`）：
```c
if (((int)snt_cnt < MINIMUM_SNT) ||   // snt_cnt は unsigned → (int)snt_cnt < 0 は常に false
    (snt_cnt < schedulable_ractor_cnt && snt_cnt < vm->ractor.sched.max_cpu))
```

`MINIMUM_SNT = 0` では第一条件が実質的に無効。コメント "for debug" から、
本番運用時に一定数の SNT を維持する用途を想定していたと推測できるが、現在は未使用。

## データとの対応

| 指標 | 値 | 関連 |
|------|-----|------|
| FlameGraph: `thread_create_core` | ~10% | SNT 補充ループの頻度 |
| rperf: `IO#read` | 47.9% | dedicated_inc の発生源 |
| rperf: `Ractor.new` | ~0.0% | 補充の主因は Ractor.new ではなくタイマー |

詳細: [findings/rperf-wall-vs-perf-cpu](rperf-wall-vs-perf-cpu.md), [findings/flamegraph-c25-m50-vs-baseline](flamegraph-c25-m50-vs-baseline.md)

## SNT_KEEP_SECONDS が有効にできない根本原因（2026-06-13 調査）

`SNT_KEEP_SECONDS = 0` が単なるデフォルト値ではなく、**クリーンアップ未実装によるメモリリーク**が理由であることが判明した。

### nt 構造体の確保と解放の非対称

SNT 作成時（`native_thread_check_and_create_shared` → `native_thread_alloc`）:

```c
// thread_pthread.c:2246-2251
struct rb_native_thread *nt = ZALLOC(struct rb_native_thread);  // (1)
nt->nt_context = ruby_xmalloc(sizeof(struct coroutine_context)); // (2)
// native_thread_create0 内で:
nt->altstack = rb_allocate_sigaltstack();                        // (3) USE_SIGALTSTACK 時
```

SNT タイムアウト終了時（`nt_start` の timeout break → `return NULL`）:

→ **(1)(2)(3) はいずれも解放されない。**

### 既存 TODO がある

[`rb_threadptr_sched_free`（:2407）](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2407) の SNT パス（`!malloc_stack`）:

```c
// thread_pthread.c:2415-2417
else {
    nt_free_stack(th->sched.context_stack);  // Ruby スレッドのスタックは解放
    // TODO: how to free nt and nt->altstack?  ← ko1 が残した TODO
}
```

### 正しいクリーンアップ手順はすでにある

[`native_thread_destroy_atfork`（:1880）](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1880) が正しい解放順を示している:

```c
// thread_pthread.c:1894-1896
RB_ALTSTACK_FREE(nt->altstack);   // (3) を解放
SIZED_FREE(nt->nt_context);       // (2) を解放
SIZED_FREE(nt);                   // (1) を解放
```

`native_thread_destroy` を呼べば条件変数も破棄できる。

### 修正の方向性

`nt_start` のタイムアウト break の直前に 2〜3 行追加するだけで SNT の cleanup が完成する:

```c
// timeout -> deleted.
native_thread_destroy(nt);  // cond 破棄 + altstack/nt_context/nt 解放
ruby_xfree(nt);
break;
```

ただし `native_thread_destroy_atfork` と `native_thread_destroy` の役割（fork 後 vs 通常）を確認してから実装すること。

詳細: [contributions/snt-keep-seconds-enable](../contributions/snt-keep-seconds-enable.md)

## 未測定の事項

- `SNT_KEEP_SECONDS = 5` に設定した場合の biryani スループット変化（クリーンアップ修正後に試すべき）
- 長時間稼働時の実際の `snt_cnt` 推移（増加し続けるか？）
- biryani 終了後の SNT 数（max_cpu を超えて蓄積しているか？）

## 関連ページ

- [internals/mn-snt-pool-growth-shrink](../internals/mn-snt-pool-growth-shrink.md) — max_cpu と SNT_KEEP_SECONDS の役割を Mermaid 図で解説
- [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md)
- [findings/futex-mn-scheduler-dedicated-nt](futex-mn-scheduler-dedicated-nt.md)
- [contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md)
- [contributions/default-max-cpu-cpu-count](../contributions/default-max-cpu-cpu-count.md)
