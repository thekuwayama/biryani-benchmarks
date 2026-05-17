# Log

セッションの時系列記録（追記専用）。

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

## [2026-05-17] setup | Wiki 初期化

wiki/ ディレクトリを初期化した。index.md / overview.md / log.md と scenarios/ findings/ internals/ ディレクトリを作成。
