#!/usr/bin/env ruby
# RUBY_MAX_CPU を変えながら h2load ベンチマークを実行する（-c25 -m50 固定）
# RUBY_MAX_CPU はサーバー起動時に設定する必要があるため、
# サーバーをフォークして都度 exec する。
#
# 実行方法: ruby load/bench_ruby_max_cpu.rb

require 'socket'

PORT = 8893
N    = 10_000
C    = 25
M    = 50
T    = 10
CPUS = [1, 2, 4, 8, 16, 32].freeze

SERVER_SCRIPT = <<~RUBY
  require 'socket'
  require 'biryani'
  socket = TCPServer.open(#{PORT})
  Ractor.new(socket) do |s|
    server = Biryani::Server.new(
      Ractor.shareable_proc do |_, res|
        res.status = 200
        res.content = 'OK'
      end
    )
    server.run(s)
  end
  sleep
RUBY

$stderr.puts "RUBY_MAX_CPU sweep (-c#{C} -m#{M} -n#{N} -t#{T})"

CPUS.each do |cpu|
  $stderr.puts "\n=== RUBY_MAX_CPU=#{cpu} ==="

  pid = fork do
    ENV['RUBY_MAX_CPU'] = cpu.to_s
    exec RbConfig.ruby, '-e', SERVER_SCRIPT
  end

  # サーバー起動を待つ
  loop do
    begin
      TCPSocket.new('localhost', PORT).close
      break
    rescue Errno::ECONNREFUSED
      sleep 0.1
    end
  end
  sleep 0.5

  system("h2load -n#{N} -c#{C} -m#{M} -t#{T} http://localhost:#{PORT}")

  Process.kill('TERM', pid)
  Process.wait(pid)
  sleep 0.5
end
