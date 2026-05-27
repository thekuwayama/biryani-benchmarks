# biryani-benchmarks — Wiki スキーマ

このリポジトリは **LLM Wiki パターン**で運用する。3 つのレイヤーで構成される。

## レイヤー構成

| レイヤー | パス | 役割 |
|---------|------|------|
| Raw Sources | `raw/` | プロファイラ・ベンチマークの生データ（不変）。LLM は読むが書かない。 |
| Schema | `CLAUDE.md`, `.claude/skills/biryani-wiki/SKILL.md`, `.claude/skills/biryani-benchmark/SKILL.md`, `.claude/skills/wiki-review/SKILL.md` | 構造・規約・ワークフローの定義 |
| Compiled Wiki | `wiki/` | Claude が生成・保守する知識ベース |

## raw/ の内容

| パス | 種別 | 説明 |
|-----|------|------|
| `raw/ruby-src/` | リポジトリ | ruby/ruby v4.0.2 ソース（git submodule） |
| `raw/biryani/` | リポジトリ | biryani ソース（git submodule、Gemfile path: 参照） |
| `raw/flamegraphs/flamegraph_<シナリオ>.svg` | 画像 | perf + FlameGraph による CPU プロファイル |
| `raw/profiles/rperf_<シナリオ>_wall.json.gz` | データセット | rperf による Ruby レベル wall time プロファイル |

`raw/*.data`（perf バイナリ）は `.gitignore` で除外。

## wiki/ の構造

```
wiki/
├── index.md                  # 全ページのカタログ（一行サマリー付き）
├── log.md                    # 時系列記録（追記専用）
├── status.md               # Ractor パフォーマンスの総合理解
├── source-reading-guide.md   # ソースコード読み方ガイド（推奨読書順・関数・行番号）
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
- raw ファイルへの参照: `raw/flamegraphs/flamegraph_c25_m50.svg` のようにパスで記述

## ruby/ruby ソース参照の規約

wiki ページ内で ruby/ruby のソースファイルや行番号を引用するときは、**必ず GitHub permalink にリンクする**。

ベース URL（サブモジュールのバージョン v4.0.2 に固定）:

```
https://github.com/ruby/ruby/blob/v4.0.2/<ファイルパス>#L<行番号>
```

| 形式 | 例 |
|------|---|
| 単一行 | `https://github.com/ruby/ruby/blob/v4.0.2/thread_pthread.c#L1366` |
| 範囲 | `https://github.com/ruby/ruby/blob/v4.0.2/thread_pthread.c#L1734-L1745` |

**Markdown での書き方**:

```markdown
<!-- インライン参照 -->
[`rb_ractor_sched_wakeup`](https://github.com/ruby/ruby/blob/v4.0.2/thread_pthread.c#L1366)（`thread_pthread.c:1366`）

<!-- テーブルの「ファイル」列 -->
| [`thread_pthread.c`](https://github.com/ruby/ruby/blob/v4.0.2/thread_pthread.c#L1734-L1745) | 1734-1745 | 内容 |

<!-- ファイルヘッダ -->
**[`ractor_sync.c`](https://github.com/ruby/ruby/blob/v4.0.2/ractor_sync.c)**
```

**例外**: コードブロック（` ``` ` ）内のコメントはリンク不可なのでそのまま。`log.md` や `questions/README.md` の流動的なメモも必須ではない。

## ワークフロー詳細

- ソースリーディング・wiki 更新・コントリビュートの手順: `.claude/skills/biryani-wiki/SKILL.md`
- ベンチマーク実行・プロファイリングの手順: `.claude/skills/biryani-benchmark/SKILL.md`
- wiki 保守（lychee・index 更新・整合性確認）の手順: `.claude/skills/wiki-review/SKILL.md`
