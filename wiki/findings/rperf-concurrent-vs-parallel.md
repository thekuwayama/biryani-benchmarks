---
date: 2026-05-23
tags: [finding]
---

# rperf の計測モデル：並行 vs 並列

rperf の数値を解釈する上での重要な前提。

## rperf が測定しているもの

rperf は**各 Ractor の視点から見た時間**をサンプリングで集計する。

```
実時間(wall clock):  |-------- 1秒 --------|

recv_loop:           |----[IO#read 待機]----|  → この1秒を IO#read にカウント
Connection:          |----[Ractor.select]---|  → この同じ1秒を Ractor.select にカウント
```

実時間では 1 秒しか経過していないが、rperf の集計では 2 秒分のサンプルとして現れる。

## 並行（rperf の視点）vs 並列（実時間の視点）

| 視点 | 計測対象 | 問いへの答え |
|------|--------|------------|
| 並行（各 Ractor 独立） | 各 Ractor が何をして時間を使っているか | rperf が答える |
| 並列（実時間） | システム全体として何が原因で遅いか | perf + FlameGraph が答える |

## 実用上の含意

- `IO#read 47.9%` + `Ractor.select 33.5%` を足して「81.4% が無駄」とは**言えない**
- 両者は同じ実時間に別の Ractor で並行して起きており、根本原因（ネットワーク待機）は同じ
- rperf の数値自体は正確——「各 Ractor がどう時間を使っているか」の観点では

## rperf と perf の使い分け

- **rperf**: Ruby メソッドレベルで「各 Ractor の行動」を把握する。どのメソッドが各 Ractorのtimeを支配しているか。
- **perf + FlameGraph**: OS レベルで実時間の CPU 使用を見る。重複カウントが起きにくく、システム全体のボトルネック特定に向く。

両方を組み合わせることで、「何をしているか（rperf）」と「なぜ遅いか（perf）」の両面から分析できる。

## 関連ページ

- [findings/rperf-wall-vs-perf-cpu](rperf-wall-vs-perf-cpu.md)
- [findings/ractor-select-wait-breakdown](ractor-select-wait-breakdown.md)
