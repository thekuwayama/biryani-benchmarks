---
date: 2026-05-23
tags: [finding]
---

# `Ractor.select` 33.5% の内訳（Q1 解決）

rperf wall モードで `-c25 -m50` を計測したとき `Ractor.select` が wall time の 33.5% を占める。
その待機時間の内訳を、biryani のアーキテクチャと C 実装から解明した。

## biryani のアーキテクチャ再確認

```
h2load クライアント
    │ TCP/HTTP2
    ▼
Connection Ractor（接続ごとに 1 つ）
    │
    ├─ recv_loop Ractor（別 Ractor）
    │       IO#read (47.9% wall)  ← ネットワーク待機
    │           └─ sock.send(frame) → @sock Port
    │
    └─ select_loop（Connection Ractor の main ループ）
            Ractor.select(@sock, @streams_ctx.tx)  ← 33.5% wall
            │
            ├─ @sock にフレーム到着 → recv_dispatch
            │       └─ リクエスト完成時: StreamContext << req
            │               └─ stream.rx.send(req)
            │                       ↓
            │               Stream Ractor（新規生成）
            │                   proc.call(req, res)  ← trivial
            │                       └─ tx.send([res, stream_id]) → @streams_ctx.tx
            │
            └─ @streams_ctx.tx にレスポンス到着 → handle_response
```

`Ractor.select(@sock, @streams_ctx.tx)` は 2 ポートを同時に待機する。

## 待機の内訳

### 主因（大部分）: recv_loop の IO#read と並行した待機

- recv_loop が `IO#read` でブロックしている間、select_loop も `Ractor.select` でブロックする
- 両者は異なる Ractor で並行動作するため、wall time はそれぞれに独立してカウントされる
- クライアントが次のフレームを送ってこなければ、recv_loop も select_loop も両方が待機状態になる
- `-c25 -m50` では 25 接続 × 最大 50 多重ストリームだが、ネットワーク RTT と h2load の送信ペースに律速される

### 副因（小部分）: Stream Ractor のレスポンス待機

- Stream Ractor が `proc.call(req, res)`（`res.status = 200; res.content = 'OK'`）を実行する時間
- trivial なハンドラなので実行時間は非常に小さく、select_loop の待機への寄与は微小

## C 実装レベルの解析

`Ractor.select` の待機は以下の経路でブロックする（[internals/ractor-select-implementation](../internals/ractor-select-implementation.md) 参照）：

```
ractor_selector__wait:
  loop:
    全ポートを ractor_try_receive でポール（N=2 なので O(1) 相当）
    メッセージなし → ractor_wait_receive → rb_ractor_sched_wait
                                              → M:N スケジューラで休眠
    wakeup（いずれかのポートへメッセージ送信時）→ 再ポール
```

wakeup のたびに全ポートを再スキャンする設計。N=2 では影響なし。

## 結論

`Ractor.select` の 33.5% は biryani のアーキテクチャの **構造的な必然**：

- ブロッキング I/O（`IO#read`）を使う限り、recv_loop と select_loop の両方がアイドルになる期間が生じる
- ノンブロッキング I/O（io_uring 等）を使えばこの比率を下げられるが、それは biryani の設計変更であり、ruby/ruby への PR 候補にはならない
- ruby/ruby 側で改善できる余地は限定的（ポート数が大きければ O(N) スキャンが問題になるが N=2 では無関係）

## 関連ページ

- [findings/rperf-wall-vs-perf-cpu](rperf-wall-vs-perf-cpu.md)
- [internals/ractor-select-implementation](../internals/ractor-select-implementation.md)
- [internals/biryani-ractor-architecture](../internals/biryani-ractor-architecture.md)
