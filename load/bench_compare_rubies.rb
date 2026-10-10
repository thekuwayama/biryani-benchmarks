#!/usr/bin/env ruby
# 実行中の Ruby で、RUBY_MAX_CPU ごとに -c25 -m50 の h2load を REPEAT 回ずつ計測する。
# Ruby のバージョン間比較用（RBENV_VERSION を変えて同じスクリプトを実行する）。
# RUBY_MAX_CPU はサーバー起動時に効くので、計測ごとにサーバーを exec し直す。
#
# 実行方法:
#   RBENV_VERSION=4.0.5 bundle exec ruby load/bench_compare_rubies.rb
#   RBENV_VERSION=master-17aeb89200 bundle exec ruby load/bench_compare_rubies.rb
# 環境変数:
#   CPUS   カンマ区切り。"unset" は RUBY_MAX_CPU 未設定（デフォルト: unset,4,8）
#   REPEAT 各条件の繰り返し回数（デフォルト: 3）

require 'socket'

PORT   = 8894
N      = 10_000
C      = 25
M      = 50
T      = 10
CPUS   = (ENV['CPUS'] || 'unset,4,8').split(',').map { |s| s == 'unset' ? nil : Integer(s) }.freeze
REPEAT = Integer(ENV['REPEAT'] || 3)

# Ruby master では IO を Ractor にコピーで渡せないため、TCPServer は Ractor 内で開く。
# BIRYANI_IO_MOVE_SHIM=1 のときは biryani の IO 受け渡しを move に差し替える
# （load/ractor_io_move_shim.rb。master で biryani 0.0.15 を動かすのに必要）。
SERVER_SCRIPT = <<~RUBY
  require 'socket'
  require 'biryani'
  require '#{File.expand_path('ractor_io_move_shim', __dir__)}' if ENV['BIRYANI_IO_MOVE_SHIM'] == '1'
  Ractor.new do
    s = TCPServer.open(#{PORT})
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

# h2load の出力から req/s・平均レイテンシ・sd・失敗数を取り出す
def parse(out)
  {
    rps: out[/finished in [\d.]+\w+, ([\d.]+) req\/s/, 1]&.to_f,
    mean: out[/time for request:\s+\S+\s+\S+\s+(\S+)\s+(\S+)/, 1],
    sd: out[/time for request:\s+\S+\s+\S+\s+\S+\s+(\S+)/, 1],
    failed: out[/(\d+) failed/, 1]&.to_i
  }
end

$stderr.puts "#{RUBY_DESCRIPTION}"
$stderr.puts "-c#{C} -m#{M} -n#{N} -t#{T}, REPEAT=#{REPEAT}, BIRYANI_IO_MOVE_SHIM=#{ENV['BIRYANI_IO_MOVE_SHIM'] || '0'}"

rows = []
CPUS.each do |cpu|
  label = cpu.nil? ? 'unset' : cpu.to_s
  REPEAT.times do |i|
    pid = fork do
      cpu.nil? ? ENV.delete('RUBY_MAX_CPU') : ENV['RUBY_MAX_CPU'] = cpu.to_s
      exec RbConfig.ruby, '-e', SERVER_SCRIPT
    end
    wait_for_server(pid)

    out = `h2load -n#{N} -c#{C} -m#{M} -t#{T} http://localhost:#{PORT}`
    r = parse(out)
    rows << [label, i + 1, r]
    $stderr.puts format('RUBY_MAX_CPU=%-5s run%d: %8.1f req/s  mean %s  sd %s  failed %d',
                        label, i + 1, r[:rps] || 0, r[:mean], r[:sd], r[:failed] || -1)

    Process.kill('TERM', pid)
    Process.wait(pid)
    sleep 0.5
  end
end

puts
puts "| RUBY_MAX_CPU | run | req/s | mean | sd | failed |"
puts '|---|---|---|---|---|---|'
rows.each do |label, i, r|
  puts "| #{label} | #{i} | #{r[:rps]} | #{r[:mean]} | #{r[:sd]} | #{r[:failed]} |"
end
