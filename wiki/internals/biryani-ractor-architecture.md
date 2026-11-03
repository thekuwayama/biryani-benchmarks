---
date: 2026-05-17
updated: 2026-11-03
tags: [internals]
---

# biryani の Ractor アーキテクチャ

biryani のソースコード（`lib/biryani/server.rb`, `connection.rb`, `stream.rb`, `streams_context.rb`）を調査した結果。

> **2026-10-11 更新（`raw/biryani` を v0.0.12 → v0.0.15 に更新）**: v0.0.14 の `0f28e70`（2026-08-15）で、
> Connection Ractor の待ち受けが **`Ractor.select(@sock, @streams_ctx.tx)` から、単一の `Ractor::Port`（`@port`）に対する `Port#receive` に変わった**。
> recv_loop と Stream Ractor はどちらも同じ `@port` に送り、Connection は先頭のタグ（`:frame` / `:response` / `:eof`）で振り分ける。
> 本ページの記述は v0.0.15 に合わせて更新した。`Ractor.select` を前提とする計測（rperf の `Ractor.select` 33.5% など）は v0.0.12 時点のもの。
>
> **2026-11-03 更新（`raw/biryani` を v0.0.15 → main `7359e96` に更新）**: v0.0.15 以降の main に 2 つの変更が入った（バージョンは 0.0.15 のまま）。
> - `cac9ff9`: IO を Ractor に**コピーではなく move で**渡すようになった（Ruby 4.1 では IO をコピーで渡せないため。→ [findings/ractor-io-copy-regression](../findings/ractor-io-copy-regression.md)）。
>   ベンチマーク用に入れていた IO move シム（`load/ractor_io_move_shim.rb`）と同じ内容なので、シムは削除した
> - `15154b8`: recv_loop が lingering close をするようになった（下記）

## Ractor の構造

```
Server#run（ループ）
  └─ TCP接続ごとに Ractor.new → Connection Ractor
       ├─ recv_loop Ractor（フレーム受信専用）
       │    └─ 共有 Ractor::Port (@port) に [:frame, obj] / :eof を送信
       └─ ストリームごとに Stream Ractor（リクエスト処理）
            └─ 同じ @port に [:response, res, stream_id] を送信

  Connection Ractor は select_loop で @port.receive し、タグで振り分ける
  （v0.0.12 までは @sock と @tx の 2 ポートを Ractor.select で待っていた）
```

### Server（`server.rb`）

```ruby
def run(socket)
  loop do
    io = socket.accept
    r = Ractor.new(@proc) do |proc|
      io_ = Ractor.receive
      conn = Connection.new(proc)
      conn.serve(io_)
    ensure
      io_&.close
    end
    r.send(io, move: true)
  end
end
```

TCP 接続を `accept` するたびに 1 つの Ractor を生成する。この Ractor が接続の全ライフサイクルを担う。
accept した IO は、生成した Ractor に `send(io, move: true)` で渡す（v0.0.15 までは `Ractor.new(socket.accept, @proc)` でコピーしていた）。

### Connection（`connection.rb`）

接続を受けた Ractor は内部でさらに 2 種類の並行処理を持つ：

**recv_loop** — フレーム受信専用の Ractor を 1 つ追加生成：
```ruby
def recv_loop(io)          # serve から recv_loop(io.clone) で呼ばれる
  r = Ractor.new(@port) do |port_|
    io_ = Ractor.receive
    eof = false
    loop do
      obj = Frame.read(io_)
      if obj.nil?
        eof = true
        port_.send(:eof, move: true)
        break
      end

      port_.send([:frame, obj], move: true)
    end

    # Lingering close
    unless eof
      begin
        Timeout.timeout(LINGER_TIMEOUT) do   # LINGER_TIMEOUT = 5
          loop { io_.readpartial(16_384) }
        end
      rescue IOError, SystemCallError, Timeout::Error
      end
    end
  ensure
    io_&.close
  end
  r.send(io, move: true)
end
```

**lingering close**（main `15154b8`）: Connection Ractor が先に終わると `@port` が閉じ、`port_.send` が `Ractor::ClosedError` を投げる。
`Ractor::ClosedError` は `StopIteration` のサブクラスなので `loop` が黙って抜け、`eof` が false のまま後半に進む。
そこで相手が閉じるまで（最大 5 秒）受信データを読み捨ててから close する。未読データを残して close すると RST が飛ぶので、それを避けるためである。
4.1.0-preview1 同梱の timeout 0.6.1 は、状態を Ractor ごとに持つ（[`Timeout::State.instance`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/lib/timeout.rb#L66-L74)（`lib/timeout.rb:66`）が `Ractor.store_if_absent` を使う）。
そのため lingering に入った recv_loop Ractor では、`Timeout.timeout` がその Ractor 用のタイムアウトスレッドを 1 つ作る。
h2load のように `-c` 本の接続を最後まで使い回す負荷では、lingering に入るのは終了時の各接続 1 回だけで、スループットへの影響は小さいはず（未計測）。

**select_loop** — 単一の `@port` から `Port#receive` で受け取り、タグで振り分ける（v0.0.14 以降）：
```ruby
def select_loop(io)
  loop do
    break if @recv_done && @streams_ctx.empty?

    case @port.receive
    in :eof
      @recv_done = true
    in [:frame, obj]
      recv_dispatch(io, obj)                # 受信フレームを処理
    in [:response, res, stream_id]
      handle_response(io, res, stream_id)   # ストリームからのレスポンスを送信
    end

    break if closed?
  end
end
```

受信フレームとレスポンスが 1 本のポートに FIFO で並ぶので、到着順に処理される。
C 実装の側では `ractor_selector__wait`（毎 wakeup で全ポートを走査）を通らなくなり、
通常の `Port#receive`（[`ractor_receive`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/ractor_sync.c#L1547)（`ractor_sync.c:1547`）→ `ractor_wait_receive`）で待つ形になる（[ractor-select-implementation](ractor-select-implementation.md) の議論は v0.0.12 向け）。

### Stream（`stream.rb`）

HTTP/2 のストリームごとに 1 つの Ractor を生成する：

```ruby
def initialize(tx, stream_id, proc)
  @rx = Ractor.new(tx, stream_id, proc) do |tx, stream_id, proc|
    unless (req = Ractor.recv).nil?
      res = HTTP::Response.default
      begin
        proc.call(req, res)
        res.validate
      rescue StandardError => e
        res = HTTP::Response.internal_server_error
      end
      tx.send([:response, res, stream_id], move: true)
    end
  end
end
```

この Ractor は：
1. `Ractor.recv` でリクエストを受け取る
2. ユーザー定義の proc を実行
3. Connection と共有する `Ractor::Port`（`tx` = Connection の `@port`）でレスポンスを送信
4. 終了（プールなし、1リクエスト1生成）

## 同時 Ractor 数の計算

| ソース | 数 |
|--------|-----|
| Connection Ractor | 接続数 = c |
| recv_loop Ractor | 接続数 = c |
| Stream Ractor | 接続数 × ストリーム数 = c × m |
| **合計** | **c × (m + 2)** |

ベースライン（`-c50 -m100`）では最大 **50 × 102 = 5,100 Ractor（= OS スレッド）** が同時に存在する。
main `15154b8` 以降は、Connection Ractor が終わった後も recv_loop Ractor が lingering close で最大 5 秒残ることがある。

## FlameGraph との対応

| FlameGraph の観察 | アーキテクチャ的な説明 |
|-------------------|----------------------|
| `thread_create_core` 12% | ストリームごとに Ractor（= OS スレッド）を生成。プールなし |
| `nt_alloc_stack` 5% | 各スレッド生成時のスタック確保コスト |
| `do_futex` / `futex_wake` 計 ~16% | ブロッキング I/O（`IO#read`）による dedicated SNT の `cond_signal` / `cond_wait`（M:N スケジューラの `cond.readyq`）。詳細は [findings/futex-mn-scheduler-dedicated-nt](../findings/futex-mn-scheduler-dedicated-nt.md) |
| GC ~11% | ストリームごとにオブジェクトが生成・破棄されるため |

## 設計上のトレードオフ

**シンプルさを優先した設計**: ストリームごとに Ractor を生成することで、各ストリームの処理が独立する。Ractor 間のデータ共有は最小限（`Ractor.make_shareable` で定数のみ共有）で、Ractor の安全性モデルを素直に使っている。

**パフォーマンス上の制約**: Ractor は OS スレッドにマッピングされるため、高並列時はスレッド生成コストと同期オーバーヘッドが大きくなる。Ractor プールを実装すれば生成コストを削減できるが、設計が複雑になる。

## 次に調べると良いこと

- `Ractor::Port` の内部実装（ruby/ruby の `ractor.c`）— futex の使われ方
- Ractor プールを実装した場合のスループット・レイテンシへの影響
- ~~`Ractor.select` が複数 Port を待つ際のスケジューリング挙動~~ → v0.0.14 で単一ポートの `Port#receive` に変わった。単一ポートに集約したことで、rperf の wall time 内訳（旧 `Ractor.select` 33.5%）がどう変わるか

## 関連ページ

- [source-reading-guide](../source-reading-guide.md) — ソースコード読み方ガイド
- [findings/flamegraph-baseline-cpu-profile](../findings/flamegraph-baseline-cpu-profile.md)
- [findings/latency-stream-multiplexing](../findings/latency-stream-multiplexing.md)
- [scenarios/baseline-default](../scenarios/baseline-default.md)
