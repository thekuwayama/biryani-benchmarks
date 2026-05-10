require_relative 'spec_helper'

RSpec.describe Biryani::Server do
  before do
    @tcpserver = TCPServer.open(PORT)

    Ractor.new(@tcpserver) do |socket|
      server = Biryani::Server.new(
        Ractor.shareable_proc do |_, res|
          res.status = 200
          res.content = 'OK'
        end
      )

      server.run(socket)
    end
  end

  after do
    @tcpserver.close
  end

  let(:h2load) do
    which('h2load')

    "h2load -n10000 -c50 -m100 -t10 http://localhost:#{PORT}"
  end

  it 'should run' do
    system(h2load)
  end
end
