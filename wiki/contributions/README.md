---
date: 2026-05-17
updated: 2026-10-11
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
| SNT 補充オーバーヘッド削減（ヒステリシス案） | 調査中（縮小側は上流で実装済み。次の実験: master `17aeb89200` で再計測）|

詳細: [contributions/snt-replenishment-overhead](snt-replenishment-overhead.md)

## クローズ済み

| 候補 | 理由 |
|------|------|
| broadcast → signal | Linux では `pthread_cond_broadcast` は走らない（Win32 のみ） |
| SNT タイムアウト時の nt 解放 + `SNT_KEEP_SECONDS` 有効化 | 上流で ko1 が実装済み（`dce74ebf04` nt 解放、`43793ca21a` SNT retire、`1da2eea37c` `SNT_KEEP_SECONDS` 削除） |

詳細: [contributions/cond-signal-vs-broadcast](cond-signal-vs-broadcast.md), [contributions/snt-keep-seconds-enable](snt-keep-seconds-enable.md)
