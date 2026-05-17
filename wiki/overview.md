# Overview — Ractor パフォーマンスの総合的理解

最終更新: 2026-05-17

**ゴール**: ruby/ruby の Ractor にパフォーマンスに関する issue 報告または改善 PR でコントリビュートする。

---

## 現時点の理解

### アーキテクチャ

biryani は接続ごとに 2 Ractors（Connection + recv_loop）＋ストリームごとに 1 Ractor（Stream）を生成する。プールなし・使い捨て設計。`-c50 -m100` で最大 5,100 Ractors。

詳細: [[internals/ractor-architecture]], [[internals/ractor-port-implementation]]

### スループット特性

| 構成 | 同時 Ractors | req/s |
|------|------------|-------|
| -c50 -m100（デフォルト） | 5,100 | 4,981 |
| -c25 -m50（最適） | **1,300** | **7,695** |
| -c10 -m50 | 520 | 7,489 |
| -c50 -m50 | 2,600 | 6,811 |

4コア環境での最適 Ractor 数は 1,000〜1,500 程度。それを超えると OS スケジューラのオーバーサブスクリプションでスループットが低下する。

### Wall time の内訳（rperf、-c25 -m50）

```
IO#read          47.9%  ← ソケット読み込み待ち（I/O バウンド）
Ractor.select    33.5%  ← イベントループ待機
IO#write         14.6%  ← レスポンス書き込み
Ractor.new        0.0%  ← Ractor 生成は wall time でほぼゼロ
```

**biryani は I/O バウンド**。Ractor 生成・同期は wall time のボトルネックではない。

詳細: [[findings/rperf-wall-vs-perf-cpu]]

### CPU の内訳（perf、-c25 -m50）

スレッド生成 ~10%、futex 同期 ~11%、GC ~8%、Ruby VM 実行 ~14%、unknown ~24%

CPU 時間では Ractor 生成（OS スレッド生成）と futex が目立つが、wall time では無視できる。perf と rperf は相補的なツール。

詳細: [[findings/flamegraph-c25-m50-vs-baseline]]

### Ractor::Port の仕組み

1 送信 = 1 `pthread_cond_broadcast` = 1 futex syscall（`ractor_sync.c`）。
メッセージは共通 `recv_queue` に着信し、Ractor 起床後に per-port キューへ振り分けられる。

詳細: [[internals/ractor-port-implementation]]

---

## 未解決の疑問

詳細は [[questions/README]] 参照。

1. `Ractor.select` の 33.5% の内訳（recv vs stream 応答待ちの比率）
2. `IO#read` 47.9% — ノンブロッキング I/O の採用可否
3. Ractor プールの効果（wall time ではゼロだが CPU は削減できるか）
4. `pthread_cond_broadcast` の条件付き最適化の余地

---

## コントリビュート候補

詳細は [[contributions/README]] 参照。

現時点では候補なし。上記の疑問を深掘りして根拠を固める。

---

## 関連ページ

- [[log]]
