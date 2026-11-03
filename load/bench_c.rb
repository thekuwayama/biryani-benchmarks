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

# Ruby 4.1 では IO を Ractor にコピーで渡せないため、move で渡す
r = Ractor.new do
  server = Biryani::Server.new(
    Ractor.shareable_proc do |_, res|
      res.status = 200
      res.content = 'OK'
    end
  )
  server.run(Ractor.receive)
end
r.send(socket, move: true)

CS.each do |c|
  $stderr.puts "\n=== -c#{c} ==="
  system("h2load -n#{N} -c#{c} -m#{M} -t#{T} http://localhost:#{PORT}")
end
