---
date: 2026-05-23
tags: [status]
---

# Overview — Ractor パフォーマンスの総合的理解

**ゴール**: ruby/ruby の Ractor にパフォーマンスに関する改善 PR でコントリビュートする。

---

## アーキテクチャ

biryani は接続ごとに 2 Ractors（Connection + recv_loop）＋ストリームごとに 1 Ractor（Stream）を生成する。プールなし・使い捨て設計。`-c25 -m50` で最大 1,300 Ractors。

```
h2load クライアント
    │ TCP/HTTP2
    ▼
Connection Ractor（接続ごと）
    ├─ recv_loop Ractor — IO#read でフレームを読み込み @sock に送信
    └─ select_loop — Ractor.select(@sock, @streams_ctx.tx) でディスパッチ
            ↓ リクエスト完成時
        Stream Ractor（ストリームごと）— proc.call → tx.send(res)
```

詳細: [internals/biryani-ractor-architecture](internals/biryani-ractor-architecture.md)

---

## スループット特性

| 構成 | 同時 Ractors | req/s |
|------|------------|-------|
| -c50 -m100（デフォルト） | 5,100 | 4,981 |
| -c25 -m50（最適） | **1,300** | **7,695** |
| -c25 -m50 RUBY_MAX_CPU=4 | 1,300 | **8,456**（+10%） |

4コア環境での最適 Ractor 数は 1,000〜1,500 程度。オーバーサブスクリプションで急落する。

---

## Wall time の内訳（rperf、-c25 -m50）

```
IO#read          47.9%  ← recv_loop がソケット読み込み待ち
Ractor.select    33.5%  ← select_loop が次のイベント待機
IO#write         14.6%  ← レスポンス書き込み
Ractor.new        0.0%  ← Ractor 生成は wall time でほぼゼロ
```

**biryani は I/O バウンド**。Ractor 生成・同期は wall time のボトルネックではない。

`Ractor.select` の 33.5% は `IO#read` がブロックしている間に select_loop も並行して待機する
**構造的必然**であり、2 つの Ractor の wall time が同じ実時間を別々にカウントする。
→ rperf の数値は加算できない（[findings/rperf-concurrent-vs-parallel](findings/rperf-concurrent-vs-parallel.md)）

詳細: [findings/rperf-wall-vs-perf-cpu](findings/rperf-wall-vs-perf-cpu.md),
[findings/ractor-select-wait-breakdown](findings/ractor-select-wait-breakdown.md)

---

## CPU の内訳（perf、-c25 -m50）

```
thread_create_core  ~10%  ← SNT 補充コスト（IO#read が引き金）
futex 同期          ~11%  ← ブロッキング I/O による dedicated SNT の cond_signal/wait
GC                   ~8%
Ruby VM 実行        ~14%
unknown             ~24%
```

`thread_create_core ~10%` は Ractor.new の直接コストではなく、`IO#read` が dedicated SNT を
取得するたびに `snt_cnt` が減少し、SNT 補充（`pthread_create`）が走る間接コスト。

詳細: [findings/flamegraph-c25-m50-vs-baseline](findings/flamegraph-c25-m50-vs-baseline.md),
[internals/ractor-mn-snt-lifecycle](internals/ractor-mn-snt-lifecycle.md)

---

## M:N スケジューラと SNT

Ruby 3.3+ の非 main Ractor は M:N スケジューラを使用。M Ruby スレッドを N OS スレッド（SNT）で処理。

- デフォルト SNT 上限: `default_max_cpu` = 物理 CPU 数（マージ済み（e98f95b4fd）。変更前は固定値 8）
- `IO#read` → dedicated SNT 取得 → `snt_cnt--` → `native_thread_check_and_create_shared` で補充
- ブロック中の Ractor は SNT を解放して休眠（M:N の恩恵）

詳細: [internals/ractor-mn-snt-lifecycle](internals/ractor-mn-snt-lifecycle.md)

---

## rperf vs perf — ツールの使い分け

| ツール | 視点 | 向いている問い |
|--------|------|--------------|
| rperf | 各 Ractor 独立の wall time | 各 Ractor が何をして時間を使っているか |
| perf + FlameGraph | OS レベルの実時間 CPU 使用 | システム全体のボトルネックはどこか |

rperf は並行計測（重複あり）なので複数 Ractor の数値を合算できない。

---

## 未解決の疑問（抜粋）

| Q | 内容 | 状態 |
|---|------|------|
| Q1 | Ractor.select 33.5% の内訳 | **解決**（IO#read との並行待機） |
| Q2 | IO#read のノンブロッキング化の可否 | 未解決 |
| Q3 | Ractor プールの効果 | **解決**（thread_create_core への効果は限定的） |
| Q4 | pthread_cond_broadcast の最適化 | **クローズ**（Linux では走らない） |
| Q5 | FlameGraph の thread_create_core の解釈 | **解決**（SNT 補充コスト） |
| Q6 | dedicated SNT のコストを下げられるか | 未解決 |

詳細: [questions/README](questions/README.md)

---

## コントリビュート候補

| 候補 | 状態 | 根拠 |
|------|------|------|
| `default_max_cpu` を物理 CPU 数に | **マージ済み（e98f95b4fd）** | RUBY_MAX_CPU=4 で +3%（I/O）・+5.5%（CPU）、ko1 の TODO コメント |
| SNT 補充オーバーヘッド削減 | 候補 | thread_create_core ~10%、改善案 3 つ |
| broadcast → signal | **クローズ** | Linux では broadcast は走らない |

詳細: [contributions/](contributions/)

---

## 関連ページ

- [index](index.md) — 全ページカタログ
- [log](log.md) — セッションの時系列記録
