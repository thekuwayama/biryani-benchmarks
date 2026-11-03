#!/usr/bin/env ruby
# -m の値を変えながら h2load ベンチマークを実行する

require 'socket'
require 'biryani'

PORT = 8889
N    = 10_000
C    = 50
T    = 10
MS   = [1, 5, 10, 25, 50, 100].freeze

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

MS.each do |m|
  $stderr.puts "\n=== -m#{m} ==="
  system("h2load -n#{N} -c#{C} -m#{m} -t#{T} http://localhost:#{PORT}")
end
