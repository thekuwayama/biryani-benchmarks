require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RuboCop::RakeTask.new
RSpec::Core::RakeTask.new(:spec)

desc 'load test using h2load'
RSpec::Core::RakeTask.new(:load) do |t|
  t.pattern = 'load/server_spec.rb'
  t.verbose = false
end

task default: %i[rubocop spec]
