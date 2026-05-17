---
date: 2026-05-17
tags: [internals]
---

# biryani の Ractor アーキテクチャ

biryani のソースコード（`lib/biryani/server.rb`, `connection.rb`, `stream.rb`, `streams_context.rb`）を調査した結果。

## Ractor の構造

```
Server#run（ループ）
  └─ TCP接続ごとに Ractor.new → Connection Ractor
       ├─ recv_loop Ractor（フレーム受信専用）
       │    └─ Ractor::Port (@sock) で Connection に送信
       └─ ストリームごとに Stream Ractor（リクエスト処理）
            └─ Ractor::Port (@tx) でレスポンスを Connection に返す
```

### Server（`server.rb`）

```ruby
def run(socket)
  loop do
    Ractor.new(socket.accept, @proc) do |io, proc|
      conn = Connection.new(proc)
      conn.serve(io)
      io.close
    end
  end
end
```

TCP 接続を `accept` するたびに 1 つの Ractor を生成する。この Ractor が接続の全ライフサイクルを担う。

### Connection（`connection.rb`）

接続を受けた Ractor は内部でさらに 2 種類の並行処理を持つ：

**recv_loop** — フレーム受信専用の Ractor を 1 つ追加生成：
```ruby
def recv_loop(io)
  Ractor.new(io, @sock = Ractor::Port.new) do |io_, sock_|
    loop do
      obj = Frame.read(io_)
      break if obj.nil?
      sock_.send(obj, move: true)
    end
  end
end
```

**select_loop** — `Ractor.select` で受信フレームとストリームレスポンスを多重化：
```ruby
def select_loop(io)
  loop do
    port, obj = Ractor.select(@sock, @streams_ctx.tx)
    if port == @sock
      recv_dispatch(io, obj)      # 受信フレームを処理
    else
      handle_response(io, res, stream_id)  # ストリームからのレスポンスを送信
    end
  end
end
```

### Stream（`stream.rb`）

HTTP/2 のストリームごとに 1 つの Ractor を生成する：

```ruby
def initialize(tx, stream_id, proc)
  @rx = Ractor.new(tx, stream_id, proc) do |tx, stream_id, proc|
    unless (req = Ractor.recv).nil?
      res = HTTP::Response.default
      proc.call(req, res)
      tx.send([res, stream_id], move: true)
    end
  end
end
```

この Ractor は：
1. `Ractor.recv` でリクエストを受け取る
2. ユーザー定義の proc を実行
3. `Ractor::Port (@tx)` でレスポンスを Connection Ractor に送信
4. 終了（プールなし、1リクエスト1生成）

## 同時 Ractor 数の計算

| ソース | 数 |
|--------|-----|
| Connection Ractor | 接続数 = c |
| recv_loop Ractor | 接続数 = c |
| Stream Ractor | 接続数 × ストリーム数 = c × m |
| **合計** | **c × (m + 2)** |

ベースライン（`-c50 -m100`）では最大 **50 × 102 = 5,100 Ractor（= OS スレッド）** が同時に存在する。

## FlameGraph との対応

| FlameGraph の観察 | アーキテクチャ的な説明 |
|-------------------|----------------------|
| `thread_create_core` 12% | ストリームごとに Ractor（= OS スレッド）を生成。プールなし |
| `nt_alloc_stack` 5% | 各スレッド生成時のスタック確保コスト |
| `do_futex` / `futex_wake` 計 ~16% | `Ractor.select` が内部で futex を使って Port を待機。多数のストリーム Ractor が `@tx` に送信するため競合が発生 |
| GC ~11% | ストリームごとにオブジェクトが生成・破棄されるため |

## 設計上のトレードオフ

**シンプルさを優先した設計**: ストリームごとに Ractor を生成することで、各ストリームの処理が独立する。Ractor 間のデータ共有は最小限（`Ractor.make_shareable` で定数のみ共有）で、Ractor の安全性モデルを素直に使っている。

**パフォーマンス上の制約**: Ractor は OS スレッドにマッピングされるため、高並列時はスレッド生成コストと同期オーバーヘッドが大きくなる。Ractor プールを実装すれば生成コストを削減できるが、設計が複雑になる。

## 次に調べると良いこと

- `Ractor::Port` の内部実装（ruby/ruby の `ractor.c`）— futex の使われ方
- Ractor プールを実装した場合のスループット・レイテンシへの影響
- `Ractor.select` が複数 Port を待つ際のスケジューリング挙動

## 関連ページ

- [[findings/flamegraph-baseline-cpu-profile]]
- [[findings/latency-stream-multiplexing]]
- [[scenarios/baseline-default]]
