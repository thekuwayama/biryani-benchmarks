#!/usr/bin/env ruby
# -c25 -m50 プロファイリング用サーバー + h2load

require 'socket'
require 'biryani'

PORT = 8891
N    = Integer(ENV['N'] || 10_000)
C    = 25
M    = 50
T    = 10

# Ruby master では IO を Ractor にコピーで渡せないため、TCPServer は Ractor 内で開く。
# BIRYANI_IO_MOVE_SHIM=1 で biryani の IO 受け渡しを move に差し替える（load/ractor_io_move_shim.rb）。
require_relative 'ractor_io_move_shim' if ENV['BIRYANI_IO_MOVE_SHIM'] == '1'
# BIRYANI_STREAM_POOL=<ワーカー数> で Stream Ractor をワーカープールに差し替える（load/ractor_pool_shim.rb）
require_relative 'ractor_pool_shim' if ENV['BIRYANI_STREAM_POOL']

Ractor.new do
  s = TCPServer.open(PORT)
  server = Biryani::Server.new(
    Ractor.shareable_proc do |_, res|
      res.status = 200
      res.content = 'OK'
    end
  )
  server.run(s)
end

# サーバー Ractor が listen を始めるまで待つ
begin
  TCPSocket.new('localhost', PORT).close
rescue Errno::ECONNREFUSED
  sleep 0.1
  retry
end

system("h2load -n#{N} -c#{C} -m#{M} -t#{T} http://localhost:#{PORT}")
