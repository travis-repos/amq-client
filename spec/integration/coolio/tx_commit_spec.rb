# encoding: utf-8
require 'spec_helper'
require 'integration/coolio/spec_helper'

describe "AMQ::Client::CoolioClient", "Tx.Commit", :nojruby => true do
  include EventedSpec::SpecHelper
  default_timeout 2
  let(:message) { "Hello, world!" }


  #
  # Examples
  #

  it "should confirm transaction completeness" do
    received_messages = []
    coolio_amqp_connect do |client|
      channel = AMQ::Client::Channel.new(client, 1)
      channel.open do
        exchange = AMQ::Client::Exchange.new(client, channel, "amq.fanout", :fanout)
        queue = AMQ::Client::Queue.new(client, channel)

        queue.declare(false, false, false, true) do
          queue.bind(exchange)
        end

        channel.tx_select do
          queue.consume(true) do |header, payload, delivery_tag, redelivered, exchange, routing_key, message_count|
            received_messages << message
            done
          end

          exchange.publish(message)
          channel.tx_commit
        end
      end
    end
    received_messages.should == [message]
  end
end