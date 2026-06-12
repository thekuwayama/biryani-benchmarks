---
date: 2026-05-17
updated: 2026-05-24
type: issue
status: 調査中
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

### 案 A': `SNT_KEEP_SECONDS` を有効化（2026-05-24 追加）

`SNT_KEEP_SECONDS` は M:N 初回実装（be1bbd5b7, ko1, 2023-04-10）からすでに実装済みだが、
デフォルト 0 で無効化されている。非ゼロ値を設定すると、アイドル SNT が N 秒後に自動終了する。

```c
// 案: デフォルト値を設定する
#ifndef SNT_KEEP_SECONDS
#define SNT_KEEP_SECONDS 5  // 5 秒アイドルで終了
#endif
```

`default_max_cpu`（提出済み）と同じ commit の「もう一本の TODO」。
`max_cpu` がプール上限（成長の制御）を担い、`SNT_KEEP_SECONDS` が縮小速度（解放）を担う設計。
現状は上限のみ設定されており、縮小が機能していない非対称な状態。

**効果の範囲**: ピーク負荷→低負荷への回復時に SNT プールが縮小する。biryani の
ような常時高負荷のシナリオでは即効性は低いが、長時間稼働サーバーの bursty ワークロードで有効。

**未測定事項**:
- `SNT_KEEP_SECONDS = 5` でのスループット変化
- 長時間稼働時の `snt_cnt` 推移

詳細: [findings/snt-keep-seconds-disabled](../findings/snt-keep-seconds-disabled.md)

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
| [`thread_pthread_mn.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread_mn.c#L408-L448) | 408-448 | `native_thread_check_and_create_shared` |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1749-L1763) | 1749-1763 | `native_thread_dedicated_inc` |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L1265-L1267) | 1265-1267 | `MINIMUM_SNT = 0` 定義 |
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/e98f95b4fd830c5e89941702e7b216e3212ac778/thread_pthread.c#L2113-L2146) | 2113-2146 | `native_thread_create0` (`pthread_create`) |

## 次のステップ

1. ~~`RUBY_MAX_CPU` を変えてベンチマークし、`thread_create_core` の比率の変化を測定~~ → 対応済み
2. `SNT_KEEP_SECONDS` を有効化（例: 5）してベンチマークし、スループットと `thread_create_core` 比率の変化を確認（**次の実験候補**）
3. `MINIMUM_SNT` を 1 以上にした場合の効果を測定
4. データが揃ったら ruby-dev に Issue を提出する

## 懸念点

- ヒステリシス導入は複雑度が上がる
- `MINIMUM_SNT = 0` が "for debug" というコメントの意図が不明（本番では別の値が望ましいのか？）
- 案 B は I/O 数が多い場合には逆効果になり得る（OS スレッド競合）
