# Log

セッションの時系列記録（追記専用）。

---

## [2026-05-17] internals | ractor-architecture
biryani ソース調査。接続ごと + recv_loop + ストリームごとに Ractor 生成（プールなし）。-c50 -m100 で最大 5,100 Ractor = FlameGraph のスレッド生成 12% + futex 16% の直接原因。

## [2026-05-17] profile | baseline-default
perf + FlameGraph。Ractor 生成 ~12%、futex 同期 ~16%、GC ~11%、unknown 28%。スレッド生成と同期オーバーヘッドが主要ボトルネック。

## [2026-05-17] benchmark | baseline-default
4,981 req/s（-n10000 -c50 -m100 -t10）。全リクエスト成功。レイテンシ 866ms mean / sd 240ms — ストリーム多重化によるキューイング遅延を仮説。

## [2026-05-17] setup | Wiki 初期化

wiki/ ディレクトリを初期化した。index.md / overview.md / log.md と scenarios/ findings/ internals/ ディレクトリを作成。
