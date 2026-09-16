# frozen_string_literal: true

require_relative "test_helper"

# dispatcher: :shared 共享调度池验收：
#   * 严格串行语义不变（enqueued 令牌）
#   * 激活/常驻不再每 Cell 一条线程
#   * Intermission 钝化（sweeper 触发）
#   * 停机排空 / 排队过期 / 背压 / improv 交错与 thread_per_cell 行为一致
class SharedDispatcherTest < Minitest::Test
  def setup
    @troupes = []
  end

  def teardown
    @troupes.each { |t| t.shutdown! rescue nil }
  end

  def mk_troupe(actor, **opts)
    troupe = Troupe::Testing.rehearsal(actors: [actor], dispatcher: :shared, **opts)
    @troupes << troupe
    troupe
  end

  # 注：RPC 白名单 = public_instance_methods(false)（不含继承），
  # 各 Actor 需显式定义自己的 RPC 方法。

  class PingActor < Troupe::Actor
    role_id "Ping"
    initial_props { { "n" => 0 } }

    def ping(i)
      props["n"] += 1
      i
    end

    def bump_slow(ms)
      n = props["n"] + 1
      sleep(ms / 1000.0) # 占住 Turn：若并发处理会造成丢更新
      props["n"] = n
      props["n"]
    end

    def value
      props["n"]
    end
  end

  class PassivationActor < Troupe::Actor
    role_id "Ping"
    intermission "0.2s"
    initial_props { { "n" => 0 } }

    def ping(i)
      props["n"] += 1
      i
    end

    def value
      props["n"]
    end
  end

  class TimeoutActor < Troupe::Actor
    role_id "Ping"
    initial_props { { "n" => 0 } }

    def slow_turn
      sleep 0.2
      props["n"] += 1
    end
  end

  class PoisonActor < Troupe::Actor
    role_id "Ping"
    initial_props { { "n" => 0 } }

    def ping(i)
      props["n"] += 1
      i
    end

    def boom_conflict
      raise Troupe::ConflictError, "模拟 CAS 冲突"
    end
  end

  class ImprovActor < Troupe::Actor
    role_id "Ping"
    initial_props { { "n" => 0 } }

    improv :chatty

    def ping(i)
      props["n"] += 1
      i
    end

    def bump_slow(ms)
      n = props["n"] + 1
      sleep(ms / 1000.0)
      props["n"] = n
      props["n"]
    end

    def chatty(i)
      sleep(5 / 1000.0)
      i
    end

    def value
      props["n"]
    end
  end

  def test_default_is_thread_per_cell
    troupe = Troupe::Testing.rehearsal(actors: [PingActor])
    @troupes << troupe
    assert_nil troupe.stage_manager.shared_dispatcher
  end

  def test_shared_pool_created
    troupe = mk_troupe(PingActor)
    assert_kind_of Troupe::SharedDispatcherPool, troupe.stage_manager.shared_dispatcher
  end

  def test_basic_call_roundtrip
    troupe = mk_troupe(PingActor)
    agent = troupe.cast("Ping", "p1")
    assert_equal "hello", agent.ping("hello")
    assert_equal 1, agent.value
  end

  def test_strict_serial_no_lost_update_under_concurrency
    troupe = mk_troupe(PingActor)
    agent = troupe.cast("Ping", "serial")
    agent.ping(0) # 激活
    threads = Array.new(8) do
      Thread.new do
        10.times { agent.bump_slow(2) } # 每 Turn 睡 2ms：并发处理会丢更新
      end
    end
    threads.each(&:join)
    assert_equal 81, agent.value # 1 次激活 ping + 80 次 bump
  end

  def test_activation_burst_shared_threads_bounded
    troupe = mk_troupe(PingActor, dispatcher_threads: 4)
    agents = Array.new(504) { |i| troupe.cast("Ping", "burst-#{i}") }
    concurrent(8) do |i|
      63.times { |j| agents[(i * 63) + j].ping(1) }
    end
    assert_equal 504, troupe.stage_manager.cell_count
    # 共享调度不变量：worker 线程恰为 dispatcher_threads（4），
    # 不出现每 Cell 一条调度线程（thread_per_cell 模式下会是 500+）
    workers = Thread.list.count { |t| t.name == "troupe-shared-dispatcher" }
    assert_equal 4, workers
  end

  def test_intermission_passivation_via_sweeper
    troupe = mk_troupe(PassivationActor, dispatcher_threads: 2)
    agent = troupe.cast("Ping", "pass")
    agent.ping(0)
    assert_equal 1, troupe.stage_manager.cell_count
    # intermission 0.2s + sweeper 1s 粒度 → 5s 内必然下场
    wait_until(5.0) { troupe.stage_manager.cell_count.zero? }
    # 下场后可重新激活
    assert_equal 1, agent.ping(1)
    assert_equal 2, agent.value
  end

  def test_shutdown_drains_inflight_turn
    troupe = mk_troupe(HoldActor, shutdown_grace: "3s")
    agent = troupe.cast("Ping", "sd")
    HoldActor::TURN_STARTED.clear
    results = []
    t = Thread.new { results << agent.hold(500) }
    HoldActor::TURN_STARTED.pop # 等 Turn 真正开始（确定性，不依赖 sleep 时序）
    troupe.shutdown!
    assert_equal 1, results[0] # 在飞 Turn 被排空 settle，不悬挂
    t.join(1)
    assert_raises(Troupe::CallRejectedError) { agent.ping(0) } # 停机后显式拒绝新 Call
  end

  class HoldActor < Troupe::Actor
    role_id "Ping"
    TURN_STARTED = Queue.new
    initial_props { { "n" => 0 } }

    def hold(ms)
      TURN_STARTED << true
      sleep(ms / 1000.0)
      props["n"] + 1
    end
  end

  def test_activation_limit_backpressure_shared
    troupe = mk_troupe(PingActor, activation_limit: 2)
    troupe.cast("Ping", "a1").ping(0)
    troupe.cast("Ping", "a2").ping(0)
    assert_raises(Troupe::BackpressureError) { troupe.cast("Ping", "a3").ping(0) }
  end

  def test_call_timeout_shared
    troupe = mk_troupe(TimeoutActor)
    agent = troupe.cast("Ping", "to")
    assert_raises(Troupe::CallTimeoutError) do
      agent.with_timeout("50ms").slow_turn # Turn 睡 200ms，响应期限 50ms → 超时
    end
  end

  def test_poison_invalidates_and_recovers_shared
    troupe = mk_troupe(PoisonActor)
    agent = troupe.cast("Ping", "po")
    agent.ping(0)
    assert_raises(Troupe::ConflictError) { agent.boom_conflict }
    wait_until(5.0) { troupe.stage_manager.cell_count.zero? } # 实例失效下场
    assert_equal 1, agent.ping(1) # 下次调用从已提交快照重新激活
  end

  def test_improv_interleaves_in_shared_mode
    troupe = mk_troupe(ImprovActor, dispatcher_threads: 4)
    agent = troupe.cast("Ping", "improv")
    agent.ping(0)
    results = Queue.new
    strict_thread = Thread.new do
      10.times { results << [:strict, agent.bump_slow(20)] }
    end
    improv_threads = Array.new(4) do
      Thread.new do
        5.times { |i| results << [:improv, agent.chatty(i)] }
      end
    end
    improv_threads.each(&:join)
    strict_thread.join
    stricts = 0
    improvs = 0
    until results.empty?
      (kind, _v) = results.pop
      kind == :strict ? stricts += 1 : improvs += 1
    end
    assert_equal 10, stricts
    assert_equal 20, improvs
    assert_equal 11, agent.value # 1 次激活 ping + 10 次 strict；串行性保证不丢更新
  end

  private

  # 名为 troupe-* 的线程数（共享模式应远小于 Cell 数）
  def named_dispatcher_threads
    Thread.list.count { |t| t.name&.start_with?("troupe-") }
  end
end
