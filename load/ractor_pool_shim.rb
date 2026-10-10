# biryani 0.0.15 は HTTP/2 のストリームごとに Stream Ractor を生成して使い捨てる。
# Ruby master の per-Ractor GC では、Ractor 1 つごとに objspace の生成・retire GC・
# absorb が走るので、このコストを避けたときの効果を測るため、Stream Ractor を
# 使い回すワーカープールに差し替える（biryani 本体は変更しない）。
#
# 有効化: BIRYANI_STREAM_POOL=<ワーカー数>
# - ワーカーは main Ractor がこのファイルの読み込み時に生成し、shareable な定数に置く
# - ストリームのリクエストは [req, stream_id, tx, proc] をランダムに選んだワーカーへ move で送る
#   （stream_id はどの接続でも 1, 3, 5... と同じ値になるので、振り分けには使わない）
# - Connection がエラー時に送る nil（Stream Ractor を終わらせる合図）は無視する

require 'biryani'

module Biryani
  module StreamPool
    SIZE = Integer(ENV.fetch('BIRYANI_STREAM_POOL'))

    WORKERS = Ractor.make_shareable(
      Array.new(SIZE) do
        Ractor.new do
          loop do
            req, stream_id, tx, proc = Ractor.receive
            res = HTTP::Response.default

            begin
              proc.call(req, res)
              res.validate
            rescue StandardError => e
              puts e.backtrace
              res = HTTP::Response.internal_server_error
            end

            tx.send([:response, res, stream_id], move: true)
          end
        end
      end
    )

    # Stream#rx の代わり。Connection からは rx.send(req, move: true) としか呼ばれない
    class Handle
      def initialize(tx, stream_id, proc)
        @tx = tx
        @stream_id = stream_id
        @proc = proc
      end

      def send(req, move: false)
        return if req.nil?

        WORKERS[Random.rand(SIZE)].send([req, @stream_id, @tx, @proc], move: move)
      end
    end
  end

  class Stream
    def initialize(tx, stream_id, proc)
      @rx = StreamPool::Handle.new(tx, stream_id, proc)
    end
  end
end
