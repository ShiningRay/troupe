# frozen_string_literal: true

require "securerandom"

module Troupe
  module Util
    RUBY_MIN = "3.1"

    module_function

    # 启动版本检查（对标 PLAN：Node 最低版本启动检查，不满足明确报错）
    def check_ruby_version!
      return if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(RUBY_MIN)

      raise Troupe::ConfigError, "Troupe.rb 需要 Ruby >= #{RUBY_MIN}（当前 #{RUBY_VERSION}）"
    end

    # 单调时钟（秒，浮点）——进程内计时
    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # 墙钟毫秒——跨 Stage 传播 deadline、存储时间戳
    def now_ms
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond).to_i
    end

    DURATION_RE = /\A\s*(\d+(?:\.\d+)?)\s*(ms|s|m|h|d)?\s*\z/.freeze
    UNITS = { nil => 1.0, "ms" => 0.001, "s" => 1.0, "m" => 60.0, "h" => 3600.0, "d" => 86_400.0 }.freeze

    # "500ms" / "2s" / "10m" / "1h" / "1d" / 数字（秒）→ 秒（浮点）
    def parse_duration(spec, what = "时长")
      case spec
      when Numeric
        return spec.to_f if spec >= 0
      when String
        if (m = DURATION_RE.match(spec))
          return m[1].to_f * UNITS[m[2]]
        end
      end
      raise ArgumentError, "无法解析#{what} #{spec.inspect}（支持 500ms / 2s / 10m / 1h / 1d / 秒数）"
    end

    # Call id：启动随机前缀 + 进程内单调计数——比每次 SecureRandom 便宜 3 倍，
    # 唯一性由"本进程内唯一 + 跨进程前缀唯一"保证（trace/日志可读性不受影响）
    CALL_ID_PREFIX = "#{now_ms.to_s(36)}-#{SecureRandom.hex(4)}-"
    CALL_ID_LOCK = Mutex.new
    @call_seq = 0
    class << self
      attr_accessor :call_seq
    end

    def call_id
      n = CALL_ID_LOCK.synchronize { self.call_seq += 1 }
      "#{CALL_ID_PREFIX}#{n.to_s(36)}"
    end

    # 成员身份：重启即新 incarnation（DESIGN §6.2）
    def incarnation
      "#{now_ms}-#{SecureRandom.hex(4)}"
    end

    # 复合键（提醒 id 等）
    def new_id(*parts)
      parts.join("|")
    end

    # 可中断睡眠：cancel 后 sleep 立即返回 true
    class Sleeper
      def initialize
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @generation = 0
      end

      # 返回 true 表示被 cancel 提前唤醒，false 表示睡满
      def sleep(seconds)
        gen = @mutex.synchronize { @generation }
        deadline = Util.mono + seconds
        @mutex.synchronize do
          while @generation == gen
            remaining = deadline - Util.mono
            return false if remaining <= 0

            @cv.wait(@mutex, remaining)
          end
        end
        true
      end

      def cancel
        @mutex.synchronize do
          @generation += 1
          @cv.broadcast
        end
      end
    end
  end
end
