# frozen_string_literal: true

require_relative "util"
require_relative "errors"

module Troupe
  # Call（通告，DESIGN §2）：一条对 (role, stageName) 的方法调用。
  # deadline 为墙钟毫秒（跨 Stage 可比较）。
  class Call
    attr_reader :call_id, :namespace, :role_id, :stage_name, :method, :deadline_ms, :source, :call_kind
    attr_writer :args, :hop
    attr_accessor :from_stage, :box

    # source: :local | :remote | :cue | :reminder | :admin | :forward
    def initialize(namespace:, role_id:, stage_name:, method:, args:, deadline_ms:,
                   source: :local, call_id: nil, block: nil, internal: false, hop: 0)
      @call_id = call_id || Util.call_id
      @namespace = namespace
      @role_id = role_id
      @stage_name = stage_name
      @method = method.to_sym
      @args = args
      @deadline_ms = deadline_ms
      @source = source
      @block = block
      # internal=true：框架内部调用（内存 Cue），可绕过方法白名单；线路帧永远不能构造
      @internal = internal
      @hop = hop
      @box = ResponseBox.new
    end

    def internal?
      @internal
    end

    def block?
      !@block.nil?
    end

    def block_call(actor)
      @block.call(actor)
    end

    def args
      @args || []
    end

    def hop
      @hop
    end

    def key
      # namespace/role_id/stage_name 初始化后不可变，可安全记忆化（每次派发都要做表查找）
      @key ||= [@namespace, @role_id, @stage_name]
    end

    def expired?(now_ms = Util.now_ms)
      @deadline_ms && now_ms >= @deadline_ms
    end

    def remaining_s
      return nil unless @deadline_ms

      [0.0, (@deadline_ms - Util.now_ms) / 1000.0].max
    end

    # 结构化近似（热路径每次 push 都要估字节量；inspect 太贵，用类型化估算替代）
    def approx_bytes
      @approx_bytes ||= 128 + @method.to_s.bytesize + args.sum { |a| est_size(a, 2) }
    end

    private

    def est_size(v, depth)
      case v
      when String then 32 + v.bytesize
      when Numeric, Symbol, NilClass, TrueClass, FalseClass then 16
      when Array then depth.zero? ? 64 : 40 + v.sum { |e| est_size(e, depth - 1) }
      when Hash then depth.zero? ? 256 : 64 + v.size * 96
      else 256
      end
    end
  end

  # 响应盒：调用方等待执行方 settle。等待超时只放弃等待——
  # 执行占用保持到原执行结束（响应期限与执行占用分离，DESIGN §5.1）。
  class ResponseBox
    def initialize
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      @state = :pending
    end

    def settled?
      @mutex.synchronize { @state != :pending }
    end

    def settle_ok(value)
      settle(:ok, value)
    end

    def settle_error(error)
      settle(:error, error)
    end

    def wait!(deadline_ms)
      loop do
        @mutex.synchronize do
          case @state
          when :ok then return @payload
          when :error then raise @payload
          end
          if deadline_ms
            remaining = (deadline_ms - Util.now_ms) / 1000.0
            if remaining <= 0
              raise CallTimeoutError,
                    "Call 超过响应期限：结果未知——不等于失败；按幂等键重试而非假定失败（DESIGN §5.1/§6.5）"
            end
            @cv.wait(@mutex, remaining)
          else
            @cv.wait(@mutex)
          end
        end
      end
    end

    private

    def settle(state, payload)
      @mutex.synchronize do
        return false unless @state == :pending

        @state = state
        @payload = payload
        @cv.broadcast
      end
      true
    end
  end

  # 全局排队字节预算（DESIGN §5.3）：超限显式拒绝
  class ByteBudget
    attr_reader :limit, :used

    def initialize(limit)
      @limit = limit
      @used = 0
      @mutex = Mutex.new
    end

    def reserve(n)
      @mutex.synchronize do
        raise BackpressureError, "排队字节预算超限（used=#{@used} + #{n} > limit=#{@limit}）：过载显式拒绝（DESIGN §5.3）" if @used + n > @limit

        @used += n
      end
    end

    def release(n)
      @mutex.synchronize do
        @used = [@used - n, 0].max
      end
    end
  end

  # CallBoard（后台公告栏）：每 Actor 的 FIFO 邮箱（DESIGN §2、§5.3）。
  # 深度上限保护单个热点 Actor；pop 支持超时与 wake（Intermission / 停机用）。
  class CallBoard
    attr_reader :limit

    def initialize(limit:, budget: nil)
      @limit = limit
      @budget = budget
      @q = []
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      @wake_seq = 0
    end

    def push!(call)
      @mutex.synchronize do
        raise BoardFullError, "CallBoard 已满（limit=#{@limit}）：单个热点 Actor 只有一个串行通道（DESIGN §5.3）" if @q.size >= @limit

        @budget&.reserve(call.approx_bytes)
        @q.push(call)
        @cv.signal
      end
      nil
    end

    # 返回 Call 或 nil（超时 / 被 wake 唤醒且队列为空）
    def pop(timeout:)
      deadline = timeout && Util.mono + timeout
      seq = @mutex.synchronize { @wake_seq }
      loop do
        @mutex.synchronize do
          if (call = @q.shift)
            @budget&.release(call.approx_bytes)
            return call
          end
          return nil if @wake_seq != seq

          if deadline.nil?
            @cv.wait(@mutex)
          else
            remaining = deadline - Util.mono
            return nil if remaining <= 0

            @cv.wait(@mutex, remaining)
          end
        end
      end
    end

    def wake!
      @mutex.synchronize do
        @wake_seq += 1
        @cv.broadcast
      end
    end

    def depth
      @mutex.synchronize { @q.size }
    end

    def drain_all!
      @mutex.synchronize do
        calls = @q
        @q = []
        calls.each { |c| @budget&.release(c.approx_bytes) }
        calls
      end
    end
  end
end
