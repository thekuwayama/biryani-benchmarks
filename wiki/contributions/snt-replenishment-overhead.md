---
date: 2026-05-17
type: issue
status: 候補
---

# M:N スケジューラ：SNT 補充コストの削減

## 問題・提案

biryani のようなブロッキング I/O が多いワークロードで、SNT プールの補充（replenishment）が
頻繁に `pthread_create` を呼び出し、CPU の ~10% を消費している。

### 補充サイクルの概要

```
IO#read 開始
  → native_thread_dedicated_inc() → snt_cnt: 8→7
    → タイマー or Ractor 生成で check_and_create
      → pthread_create (thread_create_core ~10%)

IO#read 完了
  → native_thread_dedicated_dec() → snt_cnt 回復
    → 次の IO#read でまたサイクル開始
```

補充条件（`thread_pthread_mn.c:421`）:

```c
if (((int)snt_cnt < MINIMUM_SNT) ||          // MINIMUM_SNT = 0
    (snt_cnt < schedulable_ractor_cnt &&      // biryani: 常に 1,300
     snt_cnt < vm->ractor.sched.max_cpu))     // RUBY_MAX_CPU = 8
```

SNT が 1 本でも dedicated になると即座に補充が走る設計。

## 根拠

- FlameGraph（-c25 -m50）: `thread_create_core` + `nt_alloc_stack` が ~10%
- rperf wall（-c25 -m50）: `IO#read` 47.9% — blocking I/O が頻発
- 合算して M:N 管理オーバーヘッドは CPU の ~21%（`thread_create_core` ~10% + futex ~11%）

詳細: [findings/futex-mn-scheduler-dedicated-nt](../findings/futex-mn-scheduler-dedicated-nt.md), [internals/ractor-mn-snt-lifecycle](../internals/ractor-mn-snt-lifecycle.md)

## 改善アイデア

### 案 A: ヒステリシス付き補充

> **ヒステリシス（hysteresis）**: 制御工学の用語。変化にすぐ反応せず、一定の遅延・閾値を設けることで不要な反応の繰り返しを防ぐ設計パターン。例：サーモスタットが 20℃ を 0.1℃ 下回るたびに ON/OFF するのではなく、19℃ で ON・21℃ で OFF にすることで無駄なスイッチングを避ける。

SNT が dedicated になっても即座に補充せず、一定時間（数十マイクロ秒）待ってから判断する。
短命なブロッキング操作では補充不要な場合が多い。

```c
// 現在
if (snt_cnt < ractor_cnt && snt_cnt < max_cpu) { pthread_create(...); }

// 提案: タイムスタンプベースのヒステリシス
if (snt_cnt < ractor_cnt && snt_cnt < max_cpu &&
    time_since_last_dedicated > REPLENISH_DELAY) { pthread_create(...); }
```

### 案 B: `RUBY_MAX_CPU` を増やす（実験的）

より多くの SNT を事前確保することで dedicated 化の影響を吸収する。
`RUBY_MAX_CPU=16` 等でテスト可能。副作用として OS スレッド数が増える。

### 案 C: ノンブロッキング I/O（biryani 側の変更）

ruby/ruby ではなく biryani が `IO#read_nonblock` + epoll を使えば、
dedicated SNT 自体が発生しなくなり `thread_create_core` と futex の双方が削減される。
ただしこれは biryani のアーキテクチャ変更で ruby/ruby へのコントリビュートではない。

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| `thread_pthread_mn.c` | 408-448 | `native_thread_check_and_create_shared` |
| `thread_pthread.c` | 1749-1763 | `native_thread_dedicated_inc` |
| `thread_pthread.c` | 1265-1267 | `MINIMUM_SNT = 0` 定義 |
| `thread_pthread.c` | 2113-2146 | `native_thread_create0` (`pthread_create`) |

## 次のステップ

1. `RUBY_MAX_CPU` を変えてベンチマークし、`thread_create_core` の比率の変化を測定
2. `MINIMUM_SNT` を 1 以上にした場合の効果を測定
3. ruby-dev に "Is frequent SNT replenishment expected?" として問い合わせる
4. データが揃ったら Issue を作成する

## 懸念点

- ヒステリシス導入は複雑度が上がる
- `MINIMUM_SNT = 0` が "for debug" というコメントの意図が不明（本番では別の値が望ましいのか？）
- 案 B は I/O 数が多い場合には逆効果になり得る（OS スレッド競合）
