---
date: 2026-05-17
updated: 2026-05-27
tags: [contribution]
---

# Contributions — ruby/ruby コントリビュート候補

## 判断基準

コントリビュートとして提出するには：
1. ベンチマーク数値で裏付けられている
2. プロファイラ結果（rperf / perf）で根拠がある
3. ruby/ruby の関連コードが特定できている
4. 再現可能なシナリオがある

## マージ済み

| 候補 | 状態 |
|------|------|
| `default_max_cpu` を物理 CPU 数に | **マージ済み（e98f95b4fd）** |

詳細: [contributions/default-max-cpu-cpu-count](default-max-cpu-cpu-count.md)

## 調査中

| 候補 | 状態 |
|------|------|
| SNT 補充オーバーヘッド削減（`SNT_KEEP_SECONDS` 有効化・ヒステリシス案） | 調査中（次の実験: `SNT_KEEP_SECONDS = 5` でコンパイル）|

詳細: [contributions/snt-replenishment-overhead](snt-replenishment-overhead.md)

## クローズ済み

| 候補 | 理由 |
|------|------|
| broadcast → signal | Linux では `pthread_cond_broadcast` は走らない（Win32 のみ） |

詳細: [contributions/cond-signal-vs-broadcast](cond-signal-vs-broadcast.md)
