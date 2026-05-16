#!/usr/bin/env ruby
# -c の値を変えながら h2load ベンチマークを実行する（-m50 固定）

require 'socket'
require 'biryani'

PORT = 8890
N    = 10_000
M    = 50
T    = 10
CS   = [1, 5, 10, 25, 50, 100].freeze

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

CS.each do |c|
  $stderr.puts "\n=== -c#{c} ==="
  system("h2load -n#{N} -c#{c} -m#{M} -t#{T} http://localhost:#{PORT}")
end
