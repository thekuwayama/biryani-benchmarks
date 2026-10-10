---
date: 2026-05-23
updated: 2026-10-11
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
    ├─ recv_loop Ractor — IO#read でフレームを読み込み、共有ポート @port に [:frame, obj] を送信
    └─ select_loop — @port.receive でタグ（:frame / :response / :eof）ごとにディスパッチ
            ↓ リクエスト完成時
        Stream Ractor（ストリームごと）— proc.call → @port に [:response, res, stream_id] を送信
```

biryani v0.0.14 以降の構成（`raw/biryani` は v0.0.15）。v0.0.12 までは `Ractor.select(@sock, @streams_ctx.tx)` で 2 つのポートを待っていた。

詳細: [internals/biryani-ractor-architecture](internals/biryani-ractor-architecture.md)

---

## スループット特性

| 構成 | 同時 Ractors | req/s |
|------|------------|-------|
| -c50 -m100（デフォルト） | 5,100 | 4,981 |
| -c25 -m50（最適） | **1,300** | **7,695** |
| -c25 -m50 RUBY_MAX_CPU=4 | 1,300 | **8,456**（+10%） |
| -c25 -m50 Ruby 4.0.5 unset（=8 固定） | 1,300 | **7,464**（4.0.2 比 +4.3%、PR 未含） |
| -c25 -m50 Ruby 4.0.5 + biryani 0.0.15 unset | 1,300 | **8,238**（biryani 0.0.12 比 +10%） |
| -c25 -m50 **master `17aeb89200`** + biryani 0.0.15（IO move シム） | 1,300 | **約 3,400**（4.0.5 の約 43%、最大 RSS 2.2 GB） |

4コア環境での最適 Ractor 数は 1,000〜1,500 程度。オーバーサブスクリプションで急落する。

**master `17aeb89200` では、biryani 0.0.15 はそのままでは動かない**: IO を Ractor にコピーで渡せなくなったため（`d549b394dc`）、1 リクエストも処理できない。
**IO を move で渡すシムで動かすと、4.0.5 の約 43% に落ちる**: per-Ractor GC で Ractor 1 つごとに objspace の生成・retire GC・absorb が走り、Ractor を使い捨てる biryani はリクエストごとにそのコストを払う。
→ [scenarios/ruby-master-vs-405](scenarios/ruby-master-vs-405.md)、[findings/per-ractor-gc-ractor-churn-cost](findings/per-ractor-gc-ractor-churn-cost.md)、[findings/ractor-io-copy-regression](findings/ractor-io-copy-regression.md)

---

## Wall time の内訳（rperf、-c25 -m50）

Ruby 4.0.2 + biryani 0.0.12 での計測（`Ractor.select` は v0.0.12 の構成。v0.0.15 では単一ポートの `Port#receive` に変わったので、取り直しが必要）。

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

Ruby 4.0.2 + biryani 0.0.12（`-F 99`）:

```
thread_create_core  ~10%  ← SNT 補充コスト（IO#read が引き金）
futex 同期          ~11%  ← ブロッキング I/O による dedicated SNT の cond_signal/wait
GC                   ~8%
Ruby VM 実行        ~14%
unknown             ~24%
```

Ruby 4.0.5 + biryani 0.0.15（IO move シム、`-F 499`、ruby プロセス内の inclusive）: futex 17.2%、GC 19.3%、`vm_exec_core` 11.6%、`thread_create_core` 3.0%。
サンプリング周波数も変わっているので、上と単純には比べられない（[scenarios/ruby-master-vs-405](scenarios/ruby-master-vs-405.md)）。
master `17aeb89200` では GC が 72.6%（absorb 修正後も 38.7%）で、律速が GC に移った。

`thread_create_core ~10%` は Ractor.new の直接コストではなく、`IO#read` が dedicated SNT を
取得するたびに `snt_cnt` が減少し、SNT 補充（`pthread_create`）が走る間接コスト。

詳細: [findings/flamegraph-c25-m50-vs-baseline](findings/flamegraph-c25-m50-vs-baseline.md),
[internals/ractor-mn-snt-lifecycle](internals/ractor-mn-snt-lifecycle.md)

---

## M:N スケジューラと SNT

Ruby 3.3+ の非 main Ractor は M:N スケジューラを使用。M Ruby スレッドを N OS スレッド（SNT）で処理。

- デフォルト SNT 上限: `default_max_cpu` = CPU 数（`sysconf(_SC_NPROCESSORS_ONLN)`、オンラインの論理 CPU 数）。e98f95b4fd（2026-06-06）でマージ済み。4.0.x（4.0.7 まで）には入っておらず、master のみ。変更前は固定値 8
- `IO#read` → dedicated SNT 取得 → `snt_cnt--` → `native_thread_check_and_create_shared` で補充
- ブロック中の Ractor は SNT を解放して休眠（M:N の恩恵）
- **上流 master（`17aeb89200`、2026-10-10）での変化**: スケジューラは `thread_sched.c` / `thread_sched_mn.c` に移った。余った SNT は retire するようになり（`43793ca21a`、`SNT_KEEP_SECONDS` は削除）、タイムアウト付き待ちはタイマーホイール化され、I/O 待ちは `EPOLLONESHOT` 化された。per-Ractor GC も入った。上の CPU 内訳は Ruby 4.0.2 での計測なので、master での再計測が必要 → [internals/upstream-scheduler-changes-2026](internals/upstream-scheduler-changes-2026.md)

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
| Q2 | IO#read のノンブロッキング化の可否 | **解決**（EAGAIN 時のみ epoll パス。実測は Q7） |
| Q3 | Ractor プールの効果 | **解決**（thread_create_core への効果は限定的） |
| Q4 | pthread_cond_broadcast の最適化 | **クローズ**（Linux では走らない） |
| Q5 | FlameGraph の thread_create_core の解釈 | **解決**（SNT 補充コスト） |
| Q6 | dedicated SNT のコストを下げられるか | 一部は上流で解決（SNT retire）。master で再計測待ち |
| Q7 | biryani ノンブロッキング化の実測 | 未着手 |
| Q8 | per-Ractor GC 下で、使い捨て Ractor の回収は STW を誘発するか | 一部解決（STW より Ractor ごとの固定コストが問題） |

詳細: [questions/README](questions/README.md)

---

## コントリビュート候補

| 候補 | 状態 | 根拠 |
|------|------|------|
| `default_max_cpu` を物理 CPU 数に | **マージ済み（e98f95b4fd）** | RUBY_MAX_CPU=4 で +3%（I/O）・+5.5%（CPU）、ko1 の TODO コメント |
| SNT 補充オーバーヘッド削減 | 調査中（master で再計測待ち） | thread_create_core ~10%。縮小側は上流で実装済み |
| SNT タイムアウト時の nt 解放 + `SNT_KEEP_SECONDS` 有効化 | **クローズ**（上流で実装済み: `dce74ebf04` / `43793ca21a`） | — |
| `objspace_absorb` の free page 連結を O(N²) → O(src) に | **候補（PR）** | absorb の 99.6% がこの行。実験ビルドで Ractor 逐次生成 2.7 倍、biryani の終了処理 6 s → 0.5 s |
| master で IO を Ractor にコピーで渡せない | **候補（issue）** | 4.0.x では `#clone` で動いた。NEWS に記載なし |
| broadcast → signal | **クローズ** | Linux では broadcast は走らない |

詳細: [contributions/](contributions/)

---

## 関連ページ

- [index](index.md) — 全ページカタログ
- [log](log.md) — セッションの時系列記録
