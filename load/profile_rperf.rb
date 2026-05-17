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

socket = TCPServer.open(PORT)

Ractor.new(socket) do |s|
  server = Biryani::Server.new(
    Ractor.shareable_proc do |_, res|
      res.status = 200
      res.content = 'OK'
    end
  )
  server.run(s)
end

Rperf.start(output: '/biryani-benchmarks/raw/rperf_c25_m50_wall.json.gz', mode: :wall) do
  system("h2load -n#{N} -c#{C} -m#{M} -t#{T} http://localhost:#{PORT}")
end

puts "rperf wall profile saved to raw/rperf_c25_m50_wall.json.gz"
puts "report: rperf report --top raw/rperf_c25_m50_wall.json.gz"
