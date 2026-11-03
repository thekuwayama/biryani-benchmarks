#!/usr/bin/env ruby
# -c の値を変えながら h2load ベンチマークを実行する（-m50 固定）
# 前の run で確保したメモリを次の run に持ち越さないよう、run ごとにサーバーを起動し直す

require 'socket'

PORT = 8890
N    = 10_000
M    = 50
T    = 10
CS   = [1, 5, 10, 25, 50, 100].freeze

# Ruby 4.1 では IO を Ractor にコピーで渡せないため、move で渡す
SERVER_SCRIPT = <<~RUBY
  require 'socket'
  require 'biryani'
  socket = TCPServer.open(#{PORT})
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
  sleep
RUBY

# サーバーが起動前に落ちたら、待ち続けずに止める
def wait_for_server(pid)
  loop do
    TCPSocket.new('localhost', PORT).close
    break
  rescue Errno::ECONNREFUSED
    abort "server process #{pid} exited before listening" if Process.waitpid(pid, Process::WNOHANG)
    sleep 0.1
  end
  sleep 0.5
end

CS.each do |c|
  $stderr.puts "\n=== -c#{c} ==="

  pid = fork { exec RbConfig.ruby, '-e', SERVER_SCRIPT }
  wait_for_server(pid)

  system("h2load -n#{N} -c#{c} -m#{M} -t#{T} http://localhost:#{PORT}")

  Process.kill('TERM', pid)
  Process.wait(pid)
  sleep 0.5
end
