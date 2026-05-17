# Log

セッションの時系列記録（追記専用）。

---

## [2026-05-17] internals | SNT ライフサイクルと補充ロジック（Q5 解決）
`thread_create_core` ~10% = SNT プール補充コスト。IO#read → dedicated_inc → snt_cnt 減少 → タイマー or Ractor 生成で pthread_create。MINIMUM_SNT=0、max_cpu=8 の条件下で biryani の高 I/O 頻度が連続補充を引き起こす。

## [2026-05-17] contribution | snt-replenishment-overhead 候補登録
SNT 補充の頻繁な pthread_create（CPU ~10%）を削減する Issue 候補。改善アイデア3案（ヒステリシス・max_cpu 増加・ノンブロッキング I/O）。次ステップは RUBY_MAX_CPU を変えた実測。

## [2026-05-17] internals | pthread wakeup パスの正確な解明
`ractor_sync.c` の `rb_ractor_sched_wakeup` with `pthread_cond_broadcast` は `#else // win32` ブロック内。**Linux (pthread) では走らない**。pthread 版は `thread_pthread.c:1366` で `r_th` を M:N スケジューラ経由で起こす（`thread_sched_to_ready_common` → `rb_native_cond_signal`）。

## [2026-05-17] finding | futex 11% の真因は M:N スケジューラの dedicated NT
biryani の `IO#read` (47.9%) はブロッキング I/O → 各スレッドが dedicated SNT を取得 → I/O 完了時に `rb_native_cond_signal(&th->nt->cond.readyq)` で起こす。FlameGraph の futex ~11% はここが出所。Ractor send ではない。

## [2026-05-17] contribution | cond-signal-vs-broadcast をクローズ
前提誤り：broadcast は Win32 ブロック内のみ。Linux では関係なし。PR 候補をクローズ。

---

## [2026-05-17] meta | ゴール再定義
ruby/ruby Ractor へのコントリビュートを目標に設定。wiki に questions/ と contributions/ を追加。5ステップのサイクル（ソースリーディング→ベンチマーク→プロファイラ→テストシナリオ→議論）を設計。

## [2026-05-17] profile | rperf-wall-c25-m50
rperf wall モード。IO#read 47.9%、Ractor.select 33.5%、IO#write 14.6%、Ractor.new 0.0%。biryani は I/O バウンドと判明。

## [2026-05-17] profile | c25-m50-vs-baseline
-c25 -m50 FlameGraph。Ractor 生成 ~10%（baseline 比 ▼44%）、futex ~11%（▼31%）、vm_exec_core ~14%（▲40%）。Ractor 数削減で有効仕事の割合が増加。

## [2026-05-17] benchmark | sweep-c-parameter
-c=10〜100 スイープ（-m50 固定）。ピークは c=25 の 7,695 req/s（全体最高）。c=50 より 13% 高スループット・レイテンシ 2.5× 低。最適 Ractor 数は 1,000〜1,500 と推測。

## [2026-05-17] benchmark | sweep-m-parameter
-m=1〜100 スイープ（-c50 固定）。ピークは m=50 の 6,183 req/s。m=100 で逆に低下（オーバーサブスクリプション）。レイテンシは m に線形比例（m=1: 43ms → m=100: 718ms）。

## [2026-05-17] internals | ractor-port-implementation
ractor_sync.c 調査。recv_queue 二段キュー設計を解明。1送信 = 1 pthread_cond_broadcast = 1 futex syscall → FlameGraph の 16% の直接原因を確認。

## [2026-05-17] internals | ractor-architecture
biryani ソース調査。接続ごと + recv_loop + ストリームごとに Ractor 生成（プールなし）。-c50 -m100 で最大 5,100 Ractor = FlameGraph のスレッド生成 12% + futex 16% の直接原因。

## [2026-05-17] profile | baseline-default
perf + FlameGraph。Ractor 生成 ~12%、futex 同期 ~16%、GC ~11%、unknown 28%。スレッド生成と同期オーバーヘッドが主要ボトルネック。

## [2026-05-17] benchmark | baseline-default
4,981 req/s（-n10000 -c50 -m100 -t10）。全リクエスト成功。レイテンシ 866ms mean / sd 240ms — ストリーム多重化によるキューイング遅延を仮説。

## [2026-05-17] internals | M:N スレッドスケジューラの発見
「1 Ractor = 1 OS スレッド」は誤りと判明。Ruby 3.3 以降、非 main Ractor は M:N スケジューラを使用（デフォルト有効）。M Ruby スレッドを N OS スレッド（デフォルト N=8）で処理。biryani の 1,300 Ractors ≠ 1,300 OS threads。FlameGraph の thread_create_core の解釈が要再調査。

## [2026-05-17] internals | ractor-overview
Ractor 全体像ページを新設。OS スレッドマッピング（1 Ractor=1 pthread）・ライフサイクル（created/running/blocking/terminated）・共有モデル（copy/move/shareable）・Ruby 4.0 Port API・エラー体系・パフォーマンス特性を整理。

## [2026-05-17] internals | ractor-sync-wakeup
ractor_sync.c の wakeup パスを精査。発見3件: (A) rb_ractor_sched_wakeup が th 引数を無視して常に broadcast (B) ractor_wakeup_all がウェイター N 人に N 回 broadcast (C) Ractor.select が毎 wakeup で全ポートをポーリング。Q4 を PR 候補に昇格。

## [2026-05-17] contribution | cond-signal-vs-broadcast 候補登録
rb_ractor_sched_wakeup: broadcast → signal（1行変更）。th 引数が未使用・1 Ractor=1 スレッド・rb_native_cond_signal は既存 API。次ステップは ruby を patch して実測。

## [2026-05-17] meta | LLM Wiki 3レイヤー整理
raw/（Raw Sources）・CLAUDE.md（Schema）・wiki/（Compiled Wiki）の3層に整理。output/ を raw/ に改名、CLAUDE.md をプロジェクトルートに新設。

## [2026-05-17] setup | Wiki 初期化

wiki/ ディレクトリを初期化した。index.md / overview.md / log.md と scenarios/ findings/ internals/ ディレクトリを作成。
