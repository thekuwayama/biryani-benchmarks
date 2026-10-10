# Ruby master（17aeb89200）では、IO を Ractor にコピーで渡すと Ractor::Error になる
# （4.0.x では #clone で fd が dup されていた）。biryani 0.0.15 は Server#run と
# Connection#recv_loop で IO をコピーで渡しているので、move で渡すように差し替える。
# 比較の公平さのため、4.0.x / master の両方でこのシムを読み込んで計測する。

require 'biryani'

module Biryani
  class Server
    def run(socket)
      loop do
        r = Ractor.new(@proc) do |proc|
          io = Ractor.receive
          conn = Connection.new(proc)
          conn.serve(io)
          io.close
        end
        r.send(socket.accept, move: true)
      end
    end
  end

  class Connection
    def recv_loop(io)
      r = Ractor.new(@port) do |port_|
        io_ = Ractor.receive
        loop do
          obj = Frame.read(io_)
          if obj.nil?
            port_.send(:eof, move: true)
            break
          end

          port_.send([:frame, obj], move: true)
        end
      end
      r.send(io, move: true)
    end
  end
end
