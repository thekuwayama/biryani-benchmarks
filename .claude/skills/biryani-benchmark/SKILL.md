---
name: biryani-benchmark
description: |
  biryani（Ractor ベースの HTTP/2 サーバー）を使ったベンチマーク・プロファイリングスキル。h2load によるスループット計測、rperf（Ruby wall time）・perf + FlameGraph（CPU）によるプロファイリングを実行し、結果を wiki に記録する。以下を行いたい場合はこのスキルを使うこと：h2load の実行・パラメータスイープ、rperf / perf プロファイルの取得・解釈、FlameGraph の生成、ベンチマーク結果の wiki/scenarios/ または wiki/findings/ への記録。
---

# Biryani Benchmark スキル

## プロジェクトのコンテキスト

| 要素 | 詳細 |
|------|------|
| Lima VM | ベンチマーク・perf は Lima VM 上の Linux で動作。コマンドは `limactl shell --workdir /biryani-benchmarks lima bash -c 'eval "$(rbenv init -)" && <コマンド>'` |
| ベンチマークツール | `h2load`（nghttp2）— HTTP/2 ロードジェネレータ |
| プロファイラ | `perf` + `FlameGraph`（CPU）、`rperf`（Ruby メソッドレベル、wall time） |
| 結果の保存先 | シナリオ結果 → `wiki/scenarios/<名前>.md`、プロファイラ結果 → `wiki/findings/<名前>.md` |
| 生データ | `raw/flamegraphs/`（SVG）、`raw/profiles/`（rperf JSON.gz）|

**既知の最適パラメータ**: `-c25 -m50`（7,695 req/s、1,300 Ractors、4コア Lima VM）

最新のスループット比較・wall time / CPU 内訳は [wiki/status.md](../../wiki/status.md) を参照。

---

## ベンチマーク実行

カスタムパラメータ：

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

結果は必ず `wiki/scenarios/<名前>.md` に記録する。

---

## プロファイラ

### rperf（Ruby レベル、wall time）— 推奨

```bash
limactl shell --workdir /biryani-benchmarks lima bash -c '
  eval "$(rbenv init -)"
  bundle exec ruby load/profile_rperf.rb
  rperf report --top raw/profiles/rperf_c25_m50_wall.json.gz
'
```

結果は `raw/profiles/rperf_<シナリオ>_wall.json.gz` に保存される。

### perf + FlameGraph（OS/C レベル）

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

wiki ページを作成・更新したら **`/wiki-review` を呼び出して** `wiki/index.md` と `wiki/log.md` を更新すること。

---

## h2load 出力の読み方

| 指標 | 意味 |
|------|------|
| `req/s` | スループット |
| `latency mean / sd` | sd が大きい = GC ポーズや Ractor 競合 |
| `time to 1st byte` | Ractor 初期化 + 最初のレスポンスオーバーヘッド |
| `failed` | 1件でも正確性の問題として調査 |
