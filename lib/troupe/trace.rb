# frozen_string_literal: true

require_relative "errors"
require_relative "util"

module Troupe
  # 生命周期事件总线（观测埋点，PLAN M1）：轻量订阅，供测试与未来 Booth 使用
  class EventBus
    def initialize
      @lock = Mutex.new
      @subs = []
    end

    def subscribe(&blk)
      obj = Object.new
      @lock.synchronize { @subs << [obj, blk] }
      Subscription.new(self, obj)
    end

    def publish(type, **data)
      subs = @lock.synchronize { @subs.map { |_, b| b } }
      subs.each do |b|
        b.call(type, data)
      rescue StandardError
        nil
      end
    end

    def unsubscribe(token)
      @lock.synchronize { @subs.delete_if { |t, _| t.equal?(token) } }
    end
  end

  # 订阅句柄：close 退订
  class Subscription
    def initialize(bus, token)
      @bus = bus
      @token = token
    end

    def close
      @bus.unsubscribe(@token)
    end
  end

  # 每角色计数器与延迟直方图（环形缓冲，固定内存，DESIGN §11.4）
  class RoleMetrics
    DURATION_SAMPLES = 512

    def initialize
      @mutex = Mutex.new
      @calls = 0
      @errors = 0
      @rejected = 0
      @activations = 0
      @durations = []
    end

    def observe(outcome, dur_s)
      @mutex.synchronize do
        case outcome
        when :ok then @calls += 1
        when :rejected then @rejected += 1
        else @errors += 1
        end
        @durations << dur_s if outcome == :ok
        @durations.shift if @durations.size > DURATION_SAMPLES
      end
    end

    def note_activation
      @mutex.synchronize { @activations += 1 }
    end

    def snapshot
      @mutex.synchronize do
        sorted = @durations.sort
        pick = ->(p) { sorted[[0, (sorted.size * p).ceil - 1].min] }
        {
          "calls" => @calls, "errors" => @errors, "rejected" => @rejected, "activations" => @activations,
          "p50ms" => sorted.empty? ? nil : (pick.call(0.50) * 1000).round(3),
          "p99ms" => sorted.empty? ? nil : (pick.call(0.99) * 1000).round(3),
          "maxMs" => sorted.empty? ? nil : (sorted.last * 1000).round(3)
        }
      end
    end
  end

  # 全局指标（DESIGN §5.3/§11.4）
  class Metrics
    def initialize
      @lock = Mutex.new
      @roles = {}
    end

    def for_role(role_id)
      @lock.synchronize { @roles[role_id] ||= RoleMetrics.new }
    end

    def observe(role_id, outcome, dur_s)
      for_role(role_id).observe(outcome, dur_s)
    end

    def note_activation(role_id)
      for_role(role_id).note_activation
    end

    def snapshot
      @lock.synchronize { @roles.keys }.to_h do |role|
        [role, for_role(role).snapshot]
      end
    end
  end

  # Trace 事件总线（DESIGN §11.4 / PLAN M6）：
  # 每次调用产事件（调用方→被调方、方法、耗时、结果）；
  # 环形缓冲（默认 1 万条）+ 采样率 + 字节预算 + 订阅接口（CLI tail 数据源）。
  class TraceBus
    DEFAULT_CAPACITY = 10_000
    MAX_EVENT_BYTES = 4096
    MAX_SUBSCRIBERS = 16
    SUBSCRIBER_QUEUE = 1000

    def initialize(capacity: DEFAULT_CAPACITY, sample: 1.0)
      @capacity = capacity
      @sample = sample.clamp(0.0, 1.0)
      @buf = Array.new(capacity)
      @idx = 0
      @count = 0
      @bytes = 0
      @budget = capacity * MAX_EVENT_BYTES
      @subs = []
      @lock = Mutex.new
    end

    def emit(event)
      return if @sample < 1.0 && rand >= @sample

      size = event.sum { |k, v| k.to_s.bytesize + v.to_s.bytesize }
      @lock.synchronize do
        old = @buf[@idx]
        @bytes -= old_bytes(old) if old
        @buf[@idx] = event
        @bytes += size
        @idx = (@idx + 1) % @capacity
        @count += 1
        while @bytes > @budget # 预算超限自动降采样：丢最老
          @buf[(@idx - @count) % @capacity] = nil
          @count -= 1
          @bytes -= MAX_EVENT_BYTES / 2 # 近似回收，防 OOM
        end
        @subs.each do |s|
          begin
            s.push_nonblock(event)
          rescue ThreadError
            # 慢订阅者：丢弃（不阻塞调用路径）
          end
        end
      end
    rescue StandardError
      nil
    end

    def subscribe(filter = {}, &blk)
      q = SizedQueue.new(SUBSCRIBER_QUEUE)
      @lock.synchronize do
        raise BackpressureError, "trace 订阅数已达上限 #{MAX_SUBSCRIBERS}" if @subs.size >= MAX_SUBSCRIBERS

        @subs << q
      end
      pump = Thread.new do
        loop do
          ev = q.pop
          break if ev == :stop

          yield ev if matches?(filter, ev)
        end
      end
      Subscription.new(self, [q, pump])
    end

    def unsubscribe(token)
      q, pump = token
      @lock.synchronize { @subs.delete(q) }
      q.push(:stop)
      pump.join(0.5) if pump
    end

    def recent(limit = 100)
      @lock.synchronize do
        n = [@count, limit].min
        n.times.map do |i|
          @buf[(@idx - n + i) % @capacity]
        end.compact
      end
    end

    def size
      @lock.synchronize { @count }
    end

    private

    def old_bytes(ev)
      ev ? ev.sum { |k, v| k.to_s.bytesize + v.to_s.bytesize } : 0
    end

    def matches?(filter, ev)
      return true if filter.nil? || filter.empty?

      (filter["role"].nil? || ev["role"] == filter["role"]) &&
        (filter["method"].nil? || ev["method"] == filter["method"]) &&
        (filter["stageName"].nil? || ev["stageName"] == filter["stageName"])
    end
  end
end
