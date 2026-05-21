# biryani-benchmarks — Wiki スキーマ

このリポジトリは **LLM Wiki パターン**で運用する。3 つのレイヤーで構成される。

## レイヤー構成

| レイヤー | パス | 役割 |
|---------|------|------|
| Raw Sources | `raw/` | プロファイラ・ベンチマークの生データ（不変）。LLM は読むが書かない。 |
| Schema | `CLAUDE.md`, `.claude/skills/biryani-wiki/SKILL.md` | 構造・規約・ワークフローの定義 |
| Compiled Wiki | `wiki/` | Claude が生成・保守する知識ベース |

## raw/ の内容

| パス | 種別 | 説明 |
|-----|------|------|
| `raw/ruby-src/` | リポジトリ | ruby/ruby v4.0.2 ソース（git submodule） |
| `raw/flamegraph_<シナリオ>.svg` | 画像 | perf + FlameGraph による CPU プロファイル |
| `raw/rperf_<シナリオ>_wall.json.gz` | データセット | rperf による Ruby レベル wall time プロファイル |

`raw/*.data`（perf バイナリ）は `.gitignore` で除外。

## wiki/ の構造

```
wiki/
├── index.md          # 全ページのカタログ（一行サマリー付き）
├── log.md            # 時系列記録（追記専用）
├── overview.md       # Ractor パフォーマンスの総合理解
├── scenarios/        # ベンチマークシナリオ（h2load パラメータ・結果）
├── findings/         # 観察・発見・仮説（プロファイラ結果を含む）
├── internals/        # ruby/ruby ソースコード調査
├── questions/        # 未解決の疑問
└── contributions/    # issue / PR 候補
```

## wiki ページのフォーマット

```markdown
---
date: YYYY-MM-DD
tags: [scenario|finding|internals|question|contribution]
---

# タイトル

一段落のサマリー。

## 詳細

## 関連ページ

- [ページ名](相対パス.md)
```

## 図の規約

wiki ページに図が必要な場合は **Mermaid** を使う。ただし呼び出しスタック・ツリー構造は ASCII art のまま可。

## クロスリファレンス規約

- wiki ページ間: GitHub で動作する相対 Markdown リンク `[表示名](相対パス.md)`
  - 同ディレクトリ: `[foo](foo.md)`
  - 親ディレクトリ: `[bar](../findings/bar.md)`
- raw ファイルへの参照: `raw/flamegraph_c25_m50.svg` のようにパスで記述

## ワークフロー詳細

ベンチマーク実行・プロファイリング・wiki 更新の手順は `.claude/skills/biryani-wiki/SKILL.md` を参照。
