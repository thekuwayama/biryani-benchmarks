---
name: wiki-review
description: |
  biryani-benchmarks wiki の保守・レビュースキル。以下を行いたい場合はこのスキルを使うこと：lychee によるリンクチェック、wiki/index.md の更新、wiki/source-reading-guide.md へのテーブル追記、wiki ページ間の整合性確認、wiki/log.md や wiki/status.md の更新。「wiki を整理して」「整合性をチェックして」「lychee して」といった保守タスク全般。
---

# Wiki Review スキル

## 操作

### リンクチェック（lychee）

```bash
lychee 'wiki/**/*.md'
```

設定は `lychee.toml`（`max_concurrency=2`、`host_request_interval=500ms`）。
エラーがあれば該当ページを修正してから再実行する。

---

### wiki/index.md の更新

新しい wiki ページを作成したとき：

1. `wiki/index.md` の該当セクション（scenarios / findings / internals / questions / contributions）に一行サマリーを追加する
2. フォーマット: `- [ページ名](相対パス.md) — 一行サマリー`

---

### wiki/source-reading-guide.md の更新

新しい `wiki/internals/<トピック>.md` を作成したとき：

1. 対応するステップのテーブルに行を追加する
   - 「読むべき関数」「内容」「wiki 列（逆リンク）」の 3 列
   - 関数・行番号は GitHub permalink にリンクする（規約は `CLAUDE.md` の「ruby/ruby ソース参照の規約」を参照）
2. `wiki/internals/<トピック>.md` の「関連ページ」に `[source-reading-guide](../source-reading-guide.md)` を追加する

---

### wiki/log.md の更新

セッションで発見・wiki 更新があったとき、`wiki/log.md` の先頭に追記する：

```markdown
## [YYYY-MM-DD] <カテゴリ> | <タイトル>

<1〜3行の要約>

---
```

---

### wiki/status.md の更新

知見が更新されたとき（新しいスループット数値・wall time/CPU 内訳の変化・コントリビュート候補の状態変化）、該当セクションを最新状態に保つ。

---

### 整合性チェック

1. `lychee 'wiki/**/*.md'` でリンクを確認する
2. 主要ページを読み、事実の矛盾・stale な記述・ページ間の不一致を探す
   - 数値（req/s, %）が他ページと整合しているか
   - 「提出済み」「調査中」等のステータスが最新か
   - `wiki/index.md` と実ファイルが対応しているか
3. 修正があれば対象ページを編集し、lychee を再実行して確認する
