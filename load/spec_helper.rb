require 'open3'
require 'socket'
require 'biryani'

PORT = 8888

def which(cmd)
  o, = Open3.capture3("which #{cmd}")
  warn "conformance task require `#{cmd}`. Install `#{cmd}`." if o.empty?
end
