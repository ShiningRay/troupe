# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/autorun"
require "tmpdir"
require "logger"
require "troupe"

Troupe::Log.logger.level = Logger::FATAL

module TroupeTestHelpers
  # 轮询等待异步条件成立
  def wait_until(seconds = 5.0)
    deadline = Troupe::Util.mono + seconds
    loop do
      return true if yield

      raise "wait_until 超时（#{seconds}s）" if Troupe::Util.mono >= deadline

      sleep 0.01
    end
  end

  def concurrent(n)
    threads = Array.new(n) { |i| Thread.new { yield i } }
    threads.each(&:join)
  end
end

class Minitest::Test
  include TroupeTestHelpers
end
