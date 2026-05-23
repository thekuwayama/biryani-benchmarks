---
name: biryani-wiki
description: |
  Ractor（ruby/ruby）へのパフォーマンスコントリビュートを目指す知識ベース構築スキル。biryani（Ractor ベースの HTTP/2 サーバー）をベンチマークハーネスとして使い、Ractor のアーキテクチャとパフォーマンスを深く理解し、issue 報告や改善 PR につなげる。以下のいずれかを行いたい場合は必ずこのスキルを使うこと：ruby/ruby ソースコードリーディング、h2load / rperf / perf によるベンチマーク・プロファイリング、テストシナリオの検討・追加、Ractor パフォーマンスに関する議論、wiki の更新・参照、コントリビュート候補の整理。biryani-benchmarks または wiki/ に関するタスクであれば必ず呼び出すこと。
---

# Biryani Wiki スキル

## ゴール

**ruby/ruby の Ractor にコントリビュートする** — パフォーマンスに関する issue 報告または改善 PR。

biryani（Ractor を使った HTTP/2 サーバー実装）をハーネスとして使い、HTTP の豊富なベンチマークツールで Ractor をストレステストする：高い並列数は多くの Ractor を生成し、大きなリクエストボディは GC を誘発し、多様なパターンは異なる Ractor の挙動を露わにする。

## サイクル

各セッションは以下のサイクルのどこかから始まり、知識ベースを前進させる：

```mermaid
flowchart LR
    A["1. ソースリーディング"] --> B["2. ベンチマーク"]
    B --> C["3. プロファイラ精査"]
    C --> D["4. テストシナリオ検討"]
    D --> E["5. 議論・コントリビュート"]
    E --> A
```

セッション終わりに必ず：
- 発見・仮説・疑問を wiki に記録する
- 次のサイクルのステップを1つ提案する
- コントリビュート候補があれば `wiki/contributions/` に追記する

## プロジェクトのコンテキスト

| 要素 | 詳細 |
|------|------|
| プロジェクトルート | `/path/to/thekuwayama/biryani-benchmarks` |
| Lima VM | ベンチマーク・perf は Lima VM 上の Linux で動作。コマンドは `limactl shell --workdir /biryani-benchmarks lima bash -c 'eval "$(rbenv init -)" && <コマンド>'` |
| ベンチマークツール | `h2load`（nghttp2）— HTTP/2 ロードジェネレータ |
| プロファイラ | `perf` + `FlameGraph`（CPU）、`rperf`（Ruby メソッドレベル、wall time） |
| ruby/ruby ソース | `raw/ruby-src/`（v4.0.2 サブモジュール）— `ractor.c`, `ractor_sync.c`, `thread_pthread.c` など |
| Wiki | `wiki/` — Claude が書き、ユーザーが読む |

## Wiki の構造

```
wiki/
├── index.md          # 全ページのカタログ
├── log.md            # 時系列記録（追記専用）
├── overview.md       # Ractor パフォーマンスの現時点の総合理解
├── scenarios/        # ベンチマークシナリオ
├── findings/         # 観察・発見・仮説（プロファイラ結果を含む）
├── internals/        # ruby/ruby ソースコード調査
├── questions/        # ruby/ruby に問いたい未解決の疑問
└── contributions/    # issue / PR 候補
```

## 操作

### 1. ソースリーディング

ruby/ruby の Ractor 関連ソースを調査するとき：

- 対象ファイル: `raw/ruby-src/ractor.c`, `raw/ruby-src/ractor_sync.c`, `raw/ruby-src/thread_pthread.c`, `raw/ruby-src/vm_core.h`
- 調査結果を `wiki/internals/<トピック>.md` に記録する
- 発見がベンチマーク結果と結びつくなら `[[findings/...]]` とクロスリファレンスを張る
- 「なぜそう実装されているか」を問い、仮説を `wiki/questions/` に追記する

### 2. ベンチマーク

カスタムパラメータのベンチマーク：

```bash
limactl shell --workdir /biryani-benchmarks lima bash -c '
  eval "$(rbenv init -)"
  bundle exec ruby load/<スクリプト>.rb
'
```

標準シナリオ（-n10000 -c50 -m100 -t10）:
```bash
limactl shell --workdir /biryani-benchmarks lima bash -c 'eval "$(rbenv init -)" && bundle exec rake load'
```

**既知の最適パラメータ**: `-c25 -m50`（7,695 req/s、1,300 Ractors）

結果は必ず `wiki/scenarios/<名前>.md` に記録する。

### 3. プロファイラ

**rperf（Ruby レベル、wall time）— 推奨**:
```bash
limactl shell --workdir /biryani-benchmarks lima bash -c '
  eval "$(rbenv init -)"
  bundle exec ruby load/profile_rperf.rb
  rperf report --top raw/profiles/rperf_c25_m50_wall.json.gz
'
```

結果は `raw/profiles/rperf_<シナリオ>_wall.json.gz` に保存される。

**perf + FlameGraph（OS/C レベル）**:
```bash
limactl shell --workdir /biryani-benchmarks lima bash -c '
  eval "$(rbenv init -)"
  sudo env PATH="$PATH" perf record -e cpu-clock -F 99 --call-graph dwarf \
    -m 512M -o /tmp/perf.data bundle exec ruby load/<スクリプト>.rb
  sudo perf script -i /tmp/perf.data \
    | ./FlameGraph/stackcollapse-perf.pl \
    | ./FlameGraph/flamegraph.pl > raw/flamegraphs/flamegraph_<シナリオ>.svg
'
open raw/flamegraphs/flamegraph_<シナリオ>.svg
```

結果は `raw/flamegraphs/flamegraph_<シナリオ>.svg` に保存される。プロファイラ結果は `wiki/findings/<名前>.md` に記録する。

### 4. テストシナリオ検討

新しいシナリオを設計するとき：

- **何を測りたいか**を明確にする（Ractor 生成コスト / GC 圧力 / I/O 待機 / 同期オーバーヘッド）
- `load/` にスクリプトを追加して実装する
- 結果を既存の findings と比較する
- ruby/ruby のどのコードパスが変化するかをソースで確認する

**有用なシナリオの軸**:
- POST ボディサイズを変化させる（GC 圧力の定量化）
- `-c` / `-m` / `-t` のスイープ（最適点の探索）
- 接続を保持 vs 都度切断（Ractor ライフサイクルのコスト）

### 5. 議論・コントリビュート

コントリビュート候補を `wiki/contributions/<名前>.md` に記録する：

```markdown
---
date: YYYY-MM-DD
type: issue | pr
status: 候補 | 調査中 | 提出済み | クローズ
---

# タイトル

## 問題・提案

## 根拠（ベンチマーク・プロファイラ結果へのリンク）

## 関連する ruby/ruby のコード

## 次のステップ
```

コントリビュートの判断基準：
- データで裏付けられているか（ベンチマーク数値 + プロファイラ結果）
- ruby/ruby のどのコードが関係するか特定できているか
- 再現可能なシナリオがあるか

**絶対に守ること — LLM wiki ループの責任範囲**: このスキルは `wiki/contributions/` への記録までを担う。issue・PR の実際の提出は**絶対に行わない**。提出は wiki を読んだ人間が、調査内容を自分で理解した上で責任を持って行うべきである。LLM が生成した調査結果をそのまま提出することは、PR に対する本人の理解と責任が担保されないため避ける。

## 既知の知見サマリー

**アーキテクチャ**: biryani は接続ごとに 2 Ractors + ストリームごとに 1 Ractor を生成（プールなし）。`-c25 -m50` で最大 1,300 Ractors。

**スループット最適点**: `-c25 -m50` で 7,695 req/s（4コア Lima VM）。Ractor 数が 1,000〜1,500 を超えるとオーバーサブスクリプションでスループット低下。

**wall time の内訳**（rperf、-c25 -m50）:
- `IO#read` 47.9%、`Ractor.select` 33.5%、`IO#write` 14.6%、`Ractor.new` 0.0%
- **biryani は I/O バウンド** — Ractor 生成は wall time でほぼゼロ

**CPU の内訳**（perf、-c25 -m50）:
- スレッド生成 ~10%、futex 同期 ~11%、GC ~8%、Ruby VM 実行 ~14%

**Ractor wakeup の仕組み（Linux/pthread）**: 1 送信 → `rb_ractor_sched_wakeup`（`thread_pthread.c:1366`）→ `rb_native_cond_signal(&th->nt->cond.readyq)`（per-SNT、すでに signal）。`ractor_sync.c` の `pthread_cond_broadcast` は Win32 ブロック内のみで Linux では走らない。

**futex ~11% の真因**: Ractor send ではなく、ブロッキング I/O（`IO#read` 47.9%）による dedicated SNT の `pthread_cond_wait` / `signal`（M:N スケジューラの `cond.readyq`）。

## h2load 出力の読み方

| 指標 | 意味 |
|------|------|
| `req/s` | スループット |
| `latency mean / sd` | sd が大きい = GC ポーズや Ractor 競合 |
| `time to 1st byte` | Ractor 初期化 + 最初のレスポンスオーバーヘッド |
| `failed` | 1件でも正確性の問題として調査 |

## Wiki ページのフォーマット

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

図が必要な場合は **Mermaid** を使う。ただし **呼び出しスタック・ツリー構造は ASCII art のまま**でよい。

```markdown
​```mermaid
sequenceDiagram / stateDiagram-v2 / flowchart TD / ...
​```
```
