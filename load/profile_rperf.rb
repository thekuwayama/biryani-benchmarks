#!/usr/bin/env ruby
# rperf で -c25 -m50 をプロファイリング（wall モード: GVL/GC ラベル付き）

require 'socket'
require 'biryani'
require 'rperf'

PORT = 8893
N    = 10_000
C    = 25
M    = 50
T    = 10
OUT  = ENV['RPERF_OUT'] || '/biryani-benchmarks/raw/rperf_c25_m50_wall.json.gz'

# Ruby master では IO を Ractor にコピーで渡せないため、TCPServer は Ractor 内で開く。
# BIRYANI_IO_MOVE_SHIM=1 で biryani の IO 受け渡しを move に差し替える（load/ractor_io_move_shim.rb）。
require_relative 'ractor_io_move_shim' if ENV['BIRYANI_IO_MOVE_SHIM'] == '1'

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

Rperf.start(output: OUT, mode: :wall) do
  system("h2load -n#{N} -c#{C} -m#{M} -t#{T} http://localhost:#{PORT}")
end

puts "rperf wall profile saved to #{OUT}"
puts "report: rperf report --top #{OUT}"
