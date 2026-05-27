---
date: 2026-05-17
tags: [internals]
---

# M:N スケジューラの SNT ライフサイクルと補充ロジック

`thread_pthread_mn.c` の SNT 管理コードを精査した。
FlameGraph の `thread_create_core` ~10% の真因を特定する（Q5 の回答）。

## SNT の種類

| 種別 | 説明 | dedicated カウンタ |
|------|------|------------------|
| SNT（Shared Native Thread） | 複数 Ruby スレッドで共有する OS スレッド | `dedicated == 0` |
| DNT（Dedicated Native Thread） | 1 Ruby スレッドが専有する OS スレッド | `dedicated > 0` |

`vm->ractor.sched.snt_cnt` / `dnt_cnt` でそれぞれ管理される。

## SNT 補充ロジック（`native_thread_check_and_create_shared`）

```c
// thread_pthread_mn.c:408
native_thread_check_and_create_shared(rb_vm_t *vm)
{
    unsigned int schedulable_ractor_cnt = vm->ractor.cnt;
    unsigned int snt_cnt = vm->ractor.sched.snt_cnt;

    if (((int)snt_cnt < MINIMUM_SNT) ||               // MINIMUM_SNT = 0
        (snt_cnt < schedulable_ractor_cnt &&
         snt_cnt < vm->ractor.sched.max_cpu)) {        // RUBY_MAX_CPU（提出済み PR で物理 CPU 数に変更。旧デフォルト 8）

        vm->ractor.sched.snt_cnt++;
        // → native_thread_create0 → pthread_create  ← thread_create_core!
    }
}
```

この関数は2箇所から呼ばれる：

1. **Ractor 生成時** (`native_thread_create_shared` → L.543)
2. **タイマースレッドのタイムアウト時** (epoll/kqueue timeout → L.958)

## biryani における SNT 補充サイクル

```
IO#read 開始
  └─ native_thread_dedicated_inc()
       ├─ snt_cnt: 8 → 7  (snt → dnt に変換)
       └─ dnt_cnt: N → N+1

タイマースレッド or 次の Ractor 生成
  └─ native_thread_check_and_create_shared()
       ├─ snt_cnt(7) < ractor_cnt(1300) ✓
       ├─ snt_cnt(7) < max_cpu(8) ✓
       └─ pthread_create() で新 SNT 生成  ← thread_create_core

IO#read 完了
  └─ native_thread_dedicated_dec()
       ├─ snt_cnt: 7+1 → 8+1  (既に補充済みで snt_cnt = 9 になる)
       └─ dnt_cnt: N+1 → N
```

この「dedicated_inc → 補充 → dedicated_dec → 過剰」のサイクルが biryani の高い I/O 頻度により連続して発生する。

## FlameGraph との対応

| FlameGraph の表示 | 実際のコード | 比率 |
|-------------------|-------------|------|
| `thread_create_core` + `nt_alloc_stack` | `pthread_create` in `native_thread_create0` | ~10% |
| `futex_wait` / `futex_wake` | `rb_native_cond_wait/signal` in `thread_sched_wait_running_turn` / `wakeup_running_thread` | ~11% |

**合計 ~21% が M:N スケジューラの I/O 管理オーバーヘッド。**

## 条件の分析

補充条件 `snt_cnt < ractor_cnt && snt_cnt < max_cpu` で重要なのは：

- `ractor_cnt = 1,300`（biryani の -c25 -m50 時）— 常に `snt_cnt` より大きい
- `max_cpu` = 物理 CPU 数（提出済み PR で変更。旧デフォルト 8）— 実質的な上限
- `MINIMUM_SNT = 0`（コメントには "for debug" とある）

つまり SNT が 1 本でも dedicated になると補充が走り、上限 8 本まで回復しようとする。
biryani では `IO#read` が頻発するため、この補充が継続的に発生する。

## 疑問点（→ Q6 に関連）

- `MINIMUM_SNT = 0` のコメント "for debug" の意味は？本番ではより大きい値を使うべきか？
- SNT 補充にヒステリシス（変化にすぐ反応せず遅延を入れる設計）を設けることで `pthread_create` の頻度を下げられるか？
  - 例：`snt_cnt` が下がってもすぐ補充せず、一定時間待ってから判断する（短命な I/O ブロックなら補充不要のまま終わる）
- `RUBY_MAX_CPU` を増やして事前に多めの SNT を確保すれば replenishment は減るか？

## 関連ページ

- [source-reading-guide](../source-reading-guide.md) — ソースコード読み方ガイド
- [internals/ractor-overview](ractor-overview.md)（SNT の概要）
- [findings/futex-mn-scheduler-dedicated-nt](../findings/futex-mn-scheduler-dedicated-nt.md)（futex ~11% の真因）
- [findings/flamegraph-c25-m50-vs-baseline](../findings/flamegraph-c25-m50-vs-baseline.md)（FlameGraph の実測値）
- [questions/README](../questions/README.md)（Q5・Q6）
