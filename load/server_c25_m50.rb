#!/usr/bin/env ruby
# -c25 -m50 プロファイリング用サーバー + h2load

require 'socket'
require 'biryani'

PORT = 8891
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

system("h2load -n#{N} -c#{C} -m#{M} -t#{T} http://localhost:#{PORT}")
