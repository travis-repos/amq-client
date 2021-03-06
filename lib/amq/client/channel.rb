# encoding: utf-8

require "amq/client/entity"
require "amq/client/queue"
require "amq/client/exchange"

module AMQ
  module Client
    class Channel

      #
      # Behaviors
      #

      extend RegisterEntityMixin
      include Entity
      extend ProtocolMethodHandlers

      register_entity :queue,    AMQ::Client::Queue
      register_entity :exchange, AMQ::Client::Exchange

      #
      # API
      #


      class ChannelOutOfBadError < StandardError # TODO: inherit from some AMQP error class defined in amq-protocol or use it straight away.
        def initialize(max, given)
          super("Channel max is #{max}, #{given} given.")
        end
      end


      DEFAULT_REPLY_TEXT = "Goodbye".freeze

      attr_reader :id

      attr_reader :exchanges_awaiting_declare_ok, :exchanges_awaiting_delete_ok
      attr_reader :queues_awaiting_declare_ok, :queues_awaiting_delete_ok, :queues_awaiting_bind_ok, :queues_awaiting_unbind_ok, :queues_awaiting_purge_ok, :queues_awaiting_consume_ok, :queues_awaiting_cancel_ok, :queues_awaiting_get_response

      attr_accessor :flow_is_active


      def initialize(connection, id)
        super(connection)

        @id        = id
        @exchanges = Hash.new
        @queues    = Hash.new
        @consumers = Hash.new

        reset_state!

        # 65536 is here for cases when channel is opened without passing a callback in,
        # otherwise channel_mix would be nil and it causes a lot of needless headaches.
        # lets just have this default. MK.
        channel_max = if @connection.open?
                        @connection.channel_max || 65536
                      else
                        65536
                      end

        if channel_max != 0 && !(0..channel_max).include?(id)
          raise ChannelOutOfBadError.new(channel_max, id)
        end
      end

      def consumers
        @consumers
      end # consumers

      # @return  [Array<Queue>]   Collection of queues that were declared on this channel.
      def queues
        @queues.values
      end

      # @return  [Array<Exchange>]  Collection of exchanges that were declared on this channel.
      def exchanges
        @exchanges.values
      end


      # AMQP connection this channel belongs to.
      #
      # @return [AMQ::Client::Connection] Connection this channel belongs to.
      def connection
        @connection
      end # connection


      # @group Channel lifecycle

      # Opens AMQP channel.
      #
      # @api public
      def open(&block)
        @connection.send_frame(Protocol::Channel::Open.encode(@id, AMQ::Protocol::EMPTY_STRING))
        @connection.channels[@id] = self
        self.status = :opening

        self.redefine_callback :open, &block
      end

      # Closes AMQP channel.
      #
      # @api public
      def close(reply_code = 200, reply_text = DEFAULT_REPLY_TEXT, class_id = 0, method_id = 0, &block)
        @connection.send_frame(Protocol::Channel::Close.encode(@id, reply_code, reply_text, class_id, method_id))

        self.redefine_callback :close, &block
      end

      # @endgroup



      # @group Message acknowledgements

      # Acknowledge one or all messages on the channel.
      #
      # @api public
      # @see http://bit.ly/htCzCX AMQP 0.9.1 protocol documentation (Section 1.8.3.13.)
      def acknowledge(delivery_tag, multiple = false)
        @connection.send_frame(Protocol::Basic::Ack.encode(self.id, delivery_tag, multiple))

        self
      end # acknowledge(delivery_tag, multiple = false)

      # Reject a message with given delivery tag.
      #
      # @api public
      # @see http://bit.ly/htCzCX AMQP 0.9.1 protocol documentation (Section 1.8.3.14.)
      def reject(delivery_tag, requeue = true)
        @connection.send_frame(Protocol::Basic::Reject.encode(self.id, delivery_tag, requeue))

        self
      end # reject(delivery_tag, requeue = true)

      # Notifies AMQ broker that consumer has recovered and unacknowledged messages need
      # to be redelivered.
      #
      # @return [Channel]  self
      #
      # @note RabbitMQ as of 2.3.1 does not support basic.recover with requeue = false.
      # @see http://bit.ly/htCzCX AMQP 0.9.1 protocol documentation (Section 1.8.3.16.)
      # @api public
      def recover(requeue = true, &block)
        @connection.send_frame(Protocol::Basic::Recover.encode(@id, requeue))

        self.redefine_callback :recover, &block
        self
      end # recover(requeue = false, &block)

      # @endgroup



      # @group QoS and flow handling

      # Requests a specific quality of service. The QoS can be specified for the current channel
      # or for all channels on the connection.
      #
      # @note RabbitMQ as of 2.3.1 does not support prefetch_size.
      # @api public
      def qos(prefetch_size = 0, prefetch_count = 32, global = false, &block)
        @connection.send_frame(Protocol::Basic::Qos.encode(@id, prefetch_size, prefetch_count, global))

        self.redefine_callback :qos, &block
        self
      end # qos(prefetch_size = 4096, prefetch_count = 32, global = false, &block)

      # Asks the peer to pause or restart the flow of content data sent to a consumer.
      # This is a simple flow­control mechanism that a peer can use to avoid overflowing its
      # queues or otherwise finding itself receiving more messages than it can process. Note that
      # this method is not intended for window control. It does not affect contents returned to
      # Queue#get callers.
      #
      # @param [Boolean] active Desired flow state.
      #
      # @see http://bit.ly/htCzCX AMQP 0.9.1 protocol documentation (Section 1.5.2.3.)
      # @api public
      def flow(active = false, &block)
        @connection.send_frame(Protocol::Channel::Flow.encode(@id, active))

        self.redefine_callback :flow, &block
        self
      end # flow(active = false, &block)

      # @return [Boolean]  True if flow in this channel is active (messages will be delivered to consumers that use this channel).
      #
      # @api public
      def flow_is_active?
        @flow_is_active
      end # flow_is_active?

      # @endgroup



      # @group Transactions

      # Sets the channel to use standard transactions. One must use this method at least
      # once on a channel before using #tx_tommit or tx_rollback methods.
      #
      # @api public
      def tx_select(&block)
        @connection.send_frame(Protocol::Tx::Select.encode(@id))

        self.redefine_callback :tx_select, &block
        self
      end # tx_select(&block)

      # Commits AMQP transaction.
      #
      # @api public
      def tx_commit(&block)
        @connection.send_frame(Protocol::Tx::Commit.encode(@id))

        self.redefine_callback :tx_commit, &block
        self
      end # tx_commit(&block)

      # Rolls AMQP transaction back.
      #
      # @api public
      def tx_rollback(&block)
        @connection.send_frame(Protocol::Tx::Rollback.encode(@id))

        self.redefine_callback :tx_rollback, &block
        self
      end # tx_rollback(&block)

      # @endgroup



      # @group Error handling

      # Defines a callback that will be executed when channel is closed after
      # channel-level exception.
      #
      # @api public
      def on_error(&block)
        self.define_callback(:error, &block)
      end

      # @endgroup


      #
      # Implementation
      #

      def register_exchange(exchange)
        raise ArgumentError, "argument is nil!" if exchange.nil?

        @exchanges[exchange.name] = exchange
      end # register_exchange(exchange)

      # Finds exchange in the exchanges cache on this channel by name. Exchange only exists in the cache if
      # it was previously instantiated on this channel.
      #
      # @param [String] name Exchange name
      # @return [AMQ::Client::Exchange] Exchange (if found)
      # @api plugin
      def find_exchange(name)
        @exchanges[name]
      end

      def register_queue(queue)
        raise ArgumentError, "argument is nil!" if queue.nil?

        @queues[queue.name] = queue
      end # register_queue(queue)

      def find_queue(name)
        @queues[name]
      end


      def reset_state!
        @flow_is_active                = true

        @queues_awaiting_declare_ok    = Array.new
        @exchanges_awaiting_declare_ok = Array.new

        @queues_awaiting_delete_ok     = Array.new

        @exchanges_awaiting_delete_ok  = Array.new
        @queues_awaiting_purge_ok      = Array.new
        @queues_awaiting_bind_ok       = Array.new
        @queues_awaiting_unbind_ok     = Array.new
        @queues_awaiting_consume_ok    = Array.new
        @queues_awaiting_cancel_ok     = Array.new

        @queues_awaiting_get_response  = Array.new

        @callbacks                     = Hash.new
      end # reset_state!


      def handle_connection_interruption(method = nil)
        self.reset_state!
      end # handle_connection_interruption



      def handle_open_ok(open_ok)
        self.status = :opened
        self.exec_callback_once_yielding_self(:open, open_ok)
      end

      def handle_close_ok(close_ok)
        self.status = :closed
        self.exec_callback_once_yielding_self(:close, close_ok)
      end

      def handle_close(channel_close)
        self.status = :closed
        self.exec_callback_yielding_self(:error, channel_close)

        self.handle_connection_interruption(channel_close)
      end



      self.handle(Protocol::Channel::OpenOk) do |connection, frame|
        channel = connection.channels[frame.channel]
        channel.handle_open_ok(frame.decode_payload)
      end

      self.handle(Protocol::Channel::CloseOk) do |connection, frame|
        method   = frame.decode_payload
        channels = connection.channels

        channel  = channels[frame.channel]
        channels.delete(channel)
        channel.handle_close_ok(method)
      end

      self.handle(Protocol::Channel::Close) do |connection, frame|
        method   = frame.decode_payload
        channels = connection.channels
        channel  = channels[frame.channel]

        channel.handle_close(method)
      end

      self.handle(Protocol::Basic::QosOk) do |connection, frame|
        channel = connection.channels[frame.channel]
        channel.exec_callback(:qos, frame.decode_payload)
      end

      self.handle(Protocol::Basic::RecoverOk) do |connection, frame|
        channel = connection.channels[frame.channel]
        channel.exec_callback(:recover, frame.decode_payload)
      end

      self.handle(Protocol::Channel::FlowOk) do |connection, frame|
        channel  = connection.channels[frame.channel]
        method   = frame.decode_payload

        channel.flow_is_active = method.active
        channel.exec_callback(:flow, method)
      end

      self.handle(Protocol::Tx::SelectOk) do |connection, frame|
        channel = connection.channels[frame.channel]
        channel.exec_callback(:tx_select, frame.decode_payload)
      end

      self.handle(Protocol::Tx::CommitOk) do |connection, frame|
        channel = connection.channels[frame.channel]
        channel.exec_callback(:tx_commit, frame.decode_payload)
      end

      self.handle(Protocol::Tx::RollbackOk) do |connection, frame|
        channel = connection.channels[frame.channel]
        channel.exec_callback(:tx_rollback, frame.decode_payload)
      end
    end # Channel
  end # Client
end # AMQ
