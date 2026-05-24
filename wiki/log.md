# Log

セッションの時系列記録（追記専用）。

---

## [2026-05-24] internals | Ractor-local GC の現状調査（Ruby 4.0.2）
ko1 RubyKaigi 2025 "Toward Ractor Local GC" をベースにソース調査。
`_ractor_belonging_id`（RACTOR_CHECK_MODE 専用）と `rb_ractor_newobj_cache_t`（TLAB）は存在するが、
GC 本体は `gc_enter_event_start` → `rb_gc_vm_barrier()` で全 Ractor STW のまま。
Ractor-local GC は Ruby 4.0.2 未実装。copy 渡しの「ローカル GC で回収できる」は将来の方向性として正しいが現時点では未達。

---

## [2026-05-24] finding | SNT_KEEP_SECONDS = 0 — SNT プールが実行時に縮小しない（Q6 調査中）

`default_max_cpu` と同じ commit（be1bbd5b7, ko1）で導入された 3 つの `#ifndef` 定数のうち、
`SNT_KEEP_SECONDS = 0` と `MINIMUM_SNT = 0` が手つかずと判明。
`SNT_KEEP_SECONDS > 0` にするとアイドル SNT がタイムアウト終了する仕組みがすでに実装済みだが無効化。
`max_cpu`（上限・成長制御） ← PR #17100 対応済み、`SNT_KEEP_SECONDS`（縮小速度） ← 未解決の非対称構造を確認。
次の実験: `SNT_KEEP_SECONDS = 5` でコンパイルした Ruby での FlameGraph 取得。

---

## [2026-05-23] contribution | default_max_cpu PR 提出
https://github.com/ruby/ruby/pull/17100

---

## [2026-05-23] benchmark | RUBY_MAX_CPU 未設定の挙動確認
`bench_ruby_max_cpu.rb` に `nil`（未設定）ケースを追加して再実行。未設定（7,155 req/s）と =8（7,479 req/s）の差は 4% で、run-to-run ノイズ（=8 が回間で 9% 変動）の範囲内。コードパス（`default_max_cpu = 8` → `vm->ractor.sched.max_cpu = 8`）を実測で確認。未設定と明示的 =8 は同等の挙動。

---

## [2026-05-23] benchmark | CPU バウンドベンチマーク完了 — default_max_cpu PR 根拠確定
整数演算 50k iters/req のハンドラで RUBY_MAX_CPU スイープ。cpu=4（物理コア数）が 1,317 req/s でピーク。cpu=8（現デフォルト）は 1,244 req/s（-5.5%）。I/O バウンド（+3.1%）より差が大きい。両ワークロードで物理コア数が最適と確認。PR 提出の根拠が揃った。

## [2026-05-23] contribution | default_max_cpu PR 調査完了
git shallow を 2023-01-01 以降まで拡張し `git log -S "TODO: CPU num"` を実行。TODO は ko1（Koichi Sasada）が M:N 初回実装時（commit be1bbd5b7, 2023-04-10）に自分で書いたと判明。2年以上放置。sysconf は thread_pthread_mn.c で既に使用済み。guard パターンは ext/etc/etc.c が先例。実装方針確定。残作業: CPU バウンドベンチマーク + PR 提出。

## [2026-05-23] finding | Q3 解決 — Ractor プールは可能だが thread_create_core への効果は限定的
ループ型 Ractor プールは実装可能。idle Ractor は M:N スケジューラが SNT を解放するため占有しない。ただし thread_create_core ~10% の原因は IO#read → native_thread_dedicated_inc → snt_cnt-- の連鎖であり、Stream Ractor.new を減らしても補充頻度は変わらない。GC 軽減への寄与は軽微（未定量）。

## [2026-05-23] internals | Ractor.select の C 実装を完全解明
`ractor_selector__wait`（ractor_sync.c:1420）は毎 wakeup で全ポートを `ractor_try_receive` でポール → メッセージなければ `ractor_wait_receive` → `rb_ractor_sched_wait`（thread_pthread.c:1330）で M:N スケジューラに入る。Linux 版と Win32 版で実装が異なる（`#ifdef RUBY_THREAD_PTHREAD_H`）。

## [2026-05-23] finding | rperf の計測モデル — 並行（各 Ractor 独立）vs 並列（実時間）
rperf は各 Ractor の視点で wall time をサンプリングする。IO#read と Ractor.select は同じ実時間に別 Ractor で起きるため合算できない。rperf は「各 Ractor が何をしているか」、perf は「システム全体のボトルネック」に向く。

## [2026-05-23] finding | Q1 解決 — Ractor.select 33.5% はブロッキング I/O との並行待機
select_loop の `Ractor.select` 33.5% wall time は、recv_loop の `IO#read` がブロックしている間の並行待機が主因。2つの Ractor が独立して wall time を消費するため重複してカウントされる。Stream Ractor のレスポンス待機は trivial ハンドラのため寄与微小。構造的必然であり ruby/ruby への直接的な PR 候補にはならない。

---

## [2026-05-17] benchmark | RUBY_MAX_CPU スイープ（-c25 -m50）
物理コア数（4）でピーク 8,456 req/s。デフォルト(8)より+3%。16以上で急落(-18%/-43%)。thread_pthread.c:1735 に "TODO: CPU num?" コメント発見。

## [2026-05-17] contribution | default-max-cpu-cpu-count PR 候補登録
default_max_cpu=8 を sysconf(_SC_NPROCESSORS_ONLN) に変更する PR 候補。TODO コメントが開発者の意図を示す。次ステップは git log で意図確認 + CPU バウンドワークロードでの追加ベンチマーク。

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
