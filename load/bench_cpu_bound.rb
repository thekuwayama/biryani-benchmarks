#!/usr/bin/env ruby
# CPU バウンドハンドラで RUBY_MAX_CPU をスイープするベンチマーク
# default_max_cpu PR 根拠補強用 — CPU バウンドでも物理コア数が最適かを確認する
#
# 実行方法: bundle exec ruby load/bench_cpu_bound.rb

require 'socket'

PORT = 8894
N    = 3_000
C    = 25
M    = 50
T    = 10
CPUS = [1, 2, 4, 8, 16].freeze

SERVER_SCRIPT = <<~RUBY
  require 'socket'
  require 'biryani'

  socket = TCPServer.open(#{PORT})
  Ractor.new(socket) do |s|
    server = Biryani::Server.new(
      Ractor.shareable_proc do |_, res|
        result = 0
        50_000.times { |i| result += i * i }
        res.status = 200
        res.content = result.to_s
      end
    )
    server.run(s)
  end
  sleep
RUBY

$stderr.puts "CPU-bound RUBY_MAX_CPU sweep (50_000 iters/req, -c#{C} -m#{M} -n#{N} -t#{T})"

CPUS.each do |cpu|
  $stderr.puts "\n=== RUBY_MAX_CPU=#{cpu} ==="

  pid = fork do
    ENV['RUBY_MAX_CPU'] = cpu.to_s
    exec RbConfig.ruby, '-e', SERVER_SCRIPT
  end

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
