---
name: biryani-wiki
description: |
  Ruby の biryani HTTP/2 ライブラリ（Ractor ベース）のベンチマークを実行し、Ractor パフォーマンスに関する永続的な知識ベース（Wiki）を構築するスキル。以下のいずれかを行いたい場合は必ずこのスキルを使うこと：biryani に対するロードテストやベンチマークの実行、perf + FlameGraph によるプロファイリング、h2load 結果の分析、Ractor パフォーマンス Wiki の更新・参照、ruby/ruby ソースコードでの Ractor 内部実装の調査、新しいベンチマークシナリオの設計。biryani-benchmarks、Ractor パフォーマンス、または biryani-benchmarks/wiki/ の Wiki に関するタスクであれば必ず呼び出すこと。
---

# Biryani Wiki スキル

Ruby の Ractor パフォーマンスに関する、蓄積し続ける知識ベースを構築するためのスキル。ベンチマークのハーネスは `biryani` gem — Ractor を使って実装された HTTP/2 サーバー。HTTP ロードテストツールを使うと Ractor をさまざまな方法でストレステストできる：高い並列数は多くの Ractor を生成し、大きな POST ボディは GC を誘発し、多様なリクエストパターンは異なる Ractor の挙動を露わにする。セッションのたびに実データが得られる。それを Wiki に記録することで知識を複利的に積み上げていく。

## プロジェクトのコンテキスト

- **プロジェクトルート**: `/Users/tkuwayama/biryani-benchmarks`
- **Lima VM**: ベンチマークは Lima VM 上の Linux で動作する。Linux が必要なコマンド（ベンチマーク、perf）はすべて `limactl shell --workdir /biryani-benchmarks lima -- <コマンド>` を使う
- **ベンチマークツール**: `h2load`（nghttp2）— HTTP/2 ロードジェネレータ
- **プロファイリング**: `perf` + `FlameGraph`（サブモジュール: `FlameGraph/`）
- **Wiki**: プロジェクトルート内の `wiki/` — Claude が書き、ユーザーが読む

## 操作

### Setup — Wiki の初期化

ユーザーが Wiki を初めてセットアップしたいと言ったとき：

1. 以下のディレクトリ構造を作成する：
   ```
   wiki/
   ├── index.md        # 全ページのカタログ（一行サマリー付き）
   ├── log.md          # セッションの時系列記録（追記専用）
   ├── overview.md     # Ractor パフォーマンスに関する現時点の総合的な理解
   ├── scenarios/      # ベンチマークシナリオごとに1ページ
   ├── findings/       # 注目すべき観察、異常、仮説
   └── internals/      # Ractor / Ruby ソースコードの調査記録
   ```
2. 各ファイルをプレースホルダーと現在の日付で作成する
3. `wiki/log.md` にセットアップを記録する

### Benchmark — ロードテストの実行

ユーザーがベンチマークを実行したいとき：

1. シナリオのパラメータを確認する（未指定の場合はデフォルト値を使用）：
   - `-n` 総リクエスト数（デフォルト: 10000）
   - `-c` 同時接続数（デフォルト: 50）
   - `-m` 接続あたりの最大同時ストリーム数（デフォルト: 100）
   - `-t` ワーカースレッド数（デフォルト: 10）
   - HTTP メソッドとボディ（指定があれば）
2. Lima が起動しているか確認する: `limactl list`
3. 標準的なシナリオは `rake load` タスクで実行する（RSpec の before ブロックがサーバーを自動起動する）：
   ```bash
   limactl shell --workdir /biryani-benchmarks lima -- bundle exec rake load
   ```
4. カスタムパラメータが必要な場合はサーバーを別途起動してから h2load を直接実行する
5. 結果をパースして表示する（「h2load 出力の読み方」参照）
6. perf プロファイリングも実行するか確認する

### Profile — FlameGraph の生成

CPU プロファイリングを行いたいとき：

1. perf でロードテストと同時に記録する：
   ```bash
   limactl shell --workdir /biryani-benchmarks lima -- \
     sudo env PATH="$PATH" perf record -e cpu-clock -F 99 \
     --call-graph dwarf -m 512M -o output/perf.data \
     bundle exec rake load
   ```
   （`rake load` は固定リクエスト数で h2load を実行して終了するので、h2load が終われば perf も自然に終わる — Ctrl+C 不要）

2. FlameGraph を生成する：
   ```bash
   limactl shell --workdir /biryani-benchmarks lima -- \
     sudo perf script -i output/perf.data \
     | ./FlameGraph/stackcollapse-perf.pl \
     | ./FlameGraph/flamegraph.pl > output/flamegraph.svg
   ```
3. ユーザーに伝える: `output/flamegraph.svg` をブラウザで開いてください
4. ユーザーが見たものを聞き、ホットパスの解釈を一緒に行う

### Ingest — Wiki への記録

ベンチマーク、プロファイリング、調査の議論のあとに：

1. `wiki/scenarios/<シナリオ名>.md` にパラメータと結果を記録する（新規または更新）
2. 注目すべき観察（レイテンシのスパイク、GC ポーズのパターン、予想外のスループットなど）は `wiki/findings/` にページを作成する
3. 発見が全体像を変えるなら `wiki/overview.md` を更新する — 新しいデータが既存の主張と矛盾する場合は明示的に書く
4. 新しいページがあれば `wiki/index.md` を更新する
5. `wiki/log.md` に追記する：
   ```
   ## [YYYY-MM-DD] benchmark | <シナリオ名>
   <一行サマリー: 主要な指標とその意味>
   ```

1回のセッションで多くの Wiki ページを更新することがある — それは正常。`[[ページ名]]` を使って積極的にクロスリファレンスを張る。

### Query — Wiki を使って質問に答える

ユーザーが Ractor パフォーマンスやベンチマーク結果について質問したとき：

1. `wiki/index.md` を読んで関連ページを特定する
2. 関連ページを読む
3. Wiki ページを引用しながら回答を合成する
4. 答えが非自明で保存する価値があれば、finding ページとして記録することを提案する

Ractor の内部実装を調べたいとき：
- `ruby/ruby` ソースで関連コードを調査する（パスを確認するか、web 検索を使う）
- 調査結果を `wiki/internals/<トピック名>.md` に記録し、関連するシナリオ・finding ページからクロスリファレンスを張る

### Lint — Wiki のヘルスチェック

定期的に、またはユーザーが要求したとき：

以下を確認する：
- `index.md` に載っているがファイルが存在しないページ
- ファイルは存在するが `index.md` に載っていないページ
- ページ間の矛盾（明示的にフラグを立てる — 黙って解決しない）
- 新しいベンチマークデータによって古くなった主張
- 複数のページで言及されているがページがない概念
- 明らかなギャップ：未試行のシナリオ、変えたことのないパラメータ、未調査の疑問

ヘルスチェックの後、具体的な次の実験を 2〜3 個提案する。

## h2load 出力の読み方

Ractor の挙動を理解するための主要指標：

```
finished in Xs, <req/s> req/s          ← 主要スループット
requests: N total, N succeeded, N failed
status codes: N 2xx, ...
                   min     max    mean    sd     +/- sd
time for request:  ...                          ← レイテンシ分布
time to 1st byte:  ...                          ← Ractor 初期化 + 最初のレスポンスのオーバーヘッド
req/s:             min–max  mean  sd            ← スループットの安定性
```

**注目すべき点：**
- **req/s mean** — このシナリオの基準スループット
- **latency sd** — sd が大きい場合は GC ポーズや Ractor 競合によるテールレイテンシを示唆
- **time to 1st byte** — 接続ごとの Ractor 初期化コストを反映
- **failed requests** — 1 件でもあれば正確性の問題として調査すべき
- **シナリオ間の比較** — `-c`（接続数）や `-m`（ストリーム数）を変えると異なる Ractor の挙動を切り分けられる

## Wiki ページのフォーマット

```markdown
---
date: YYYY-MM-DD
tags: [scenario|finding|internals]
---

# ページタイトル

このページが何についてのものかを1段落で。

## 詳細

...

## 関連ページ

- [[関連ページ名]]
```

ページは事実に基づき簡潔に。総合的な解釈は overview に、個別の事実は各ページに。

## ループ

目標は複利的に積み上がる知識ベース。各セッションの終わりに、必ず：

1. すべての結果が Wiki に記録されていることを確認する（ingest）
2. 次に試す価値のある実験を提案する — どのパラメータを変えるか、どのシナリオを試すか
3. Ractor のソースコードで調べる価値のある未解決の疑問を挙げる

Wiki はセッションのたびに成長する。ベンチマークのたびにデータポイントが増え、調査のたびに説明が加わり、質問のたびに合成が深まる。最終的に Wiki は HTTP/2 負荷下での Ractor パフォーマンスについての信頼できる参照先になる。
