# frozen_string_literal: true

require_relative "codec"
require_relative "errors"
require_relative "trace"

module Troupe
  # Show（演出，DESIGN §2 / PLAN M7）：虚拟流 publish/subscribe。
  # Ruby 版首实现为进程内 pub/sub（消息经同一 Codec 复制边界）；TCP 转发与
  # NATS/Redis 底层可插拔列入选型，属后续里程碑。
  class Show
    attr_reader :name

    def initialize(name)
      @name = name
      @lock = Mutex.new
      @subs = {}
    end

    def publish(message)
      subs = @lock.synchronize { @subs.values }
      subs.each do |blk|
        Thread.new do
          blk.call(Codec.copy(message)) # 每个订阅者独立副本
        rescue StandardError => e
          Log.warn("show #{@name.inspect} 订阅者回调异常：#{e.class}: #{e.message}")
        end
      end
      subs.size
    end

    def subscribe(&blk)
      id = Util.call_id
      @lock.synchronize { @subs[id] = blk }
      Subscription.new(self, id)
    end

    def unsubscribe(id)
      @lock.synchronize { @subs.delete(id) }
    end

    def subscriber_count
      @lock.synchronize { @subs.size }
    end
  end
end
