# frozen_string_literal: true

require_relative "test_helper"

# PLAN M1 横切验收：激活 single-flight、严格串行、排队过期不执行、
# 响应期限与执行占用分离、保存失败实例失效、Intermission、背压。
class RuntimeTest < Minitest::Test
  def mk_troupe(**opts)
    troupe = Troupe::Testing.rehearsal(**opts)
    @troupes << troupe
    troupe
  end

  def setup
    @troupes = []
  end

  def teardown
    @troupes.each { |t| t.shutdown! rescue nil }
  end

  class CounterActor < Troupe::Actor
    initial_props { { "n" => 0, "log" => [] } }
    attr_accessor :gate

    def bump(v = 1)
      props["n"] += v
      props["log"] << "bump:#{v}"
      props["n"]
    end

    def value
      props["n"]
    end

    def boom
      raise ArgumentError, "业务失败"
    end

    def boom_after_save
      save_props
      raise RuntimeError, "已提交但响应丢失"
    end

    def stash(item)
      props["last"] = item
      props["last"]
    end

    def bump_commit(v = 1)
      props["n"] += v
      save_props # 持久成功语义
      props["n"]
    end

    def slow(ms)
      sleep(ms / 1000.0)
      props["log"] << "slow-end"
      "slow-done"
    end

    def log
      props["log"]
    end
  end

  def test_single_flight_activation_and_serial_no_interleave
    troupe = mk_troupe(actors: [CounterActor])
    activations = []
    troupe.events.subscribe { |type, _| activations << type if type == :activated }

    cart = troupe.cast(CounterActor, "c1")
    concurrent(50) { |i| cart.bump(1) }

    assert_equal 50, cart.value
    assert_equal 1, activations.size, "并发首次调用只激活一次（single-flight，DESIGN §5.2）"
  end

  def test_business_error_propagates_but_actor_survives
    troupe = mk_troupe(actors: [CounterActor])
    cart = troupe.cast(CounterActor, "c1")
    cart.bump(5)

    e = assert_raises(ArgumentError) { cart.boom }
    assert_equal "业务失败", e.message # 业务异常原样传播
    assert_equal 5, cart.value # 实例仍然在场可用
  end

  def test_committed_but_response_lost
    troupe = mk_troupe(actors: [CounterActor])
    cart = troupe.cast(CounterActor, "c1")
    cart.bump(3)

    # 保存成功后抛错：调用方收到业务失败，但 Props 已提交——下次调用从已提交状态继续
    assert_raises(RuntimeError) { cart.boom_after_save }
    assert_equal 3, cart.value
  end

  def test_queued_expired_call_never_executes
    troupe = mk_troupe(actors: [CounterActor])
    cart = troupe.cast(CounterActor, "c1")
    cart.bump(0) # 先激活

    # deadline 已过 → 不开始执行、无副作用（DESIGN §5.1）
    call = Troupe::Call.new(namespace: troupe.config.namespace, role_id: "Counter", stage_name: "c1",
                            method: :bump, args: [7], deadline_ms: Troupe::Util.now_ms - 10)
    assert_raises(Troupe::CallTimeoutError) { troupe.stage_manager.deliver(call) }
    assert_equal 0, cart.value, "排队过期不执行"
  end

  def test_timeout_releases_caller_but_not_execution_slot
    troupe = mk_troupe(actors: [CounterActor])
    cart = troupe.cast(CounterActor, "c1")

    t0 = Troupe::Util.mono
    e = assert_raises(Troupe::CallTimeoutError) do
      cart.with_timeout("0.15s").slow(500)
    end
    caller_wait = Troupe::Util.mono - t0
    assert_match(/结果未知/, e.message) # 结果未知语义（DESIGN §6.5）
    assert_operator caller_wait, :<, 0.5, "调用方按时放弃等待"

    # 执行占用保持到原执行 settle：后续 Call 等它结束才开始（不交错）
    t1 = Troupe::Util.mono
    cart.log # 只能在 slow settle 后执行
    waited = Troupe::Util.mono - t1
    assert_operator waited, :>=, 0.2, "执行占用：A 结束前 B 不执行（DESIGN §5.1）"
    assert_includes cart.log, "slow-end" # 旧任务继续跑完
  end

  # 只失败一次的 PropStore：首次写成功并武装；下一次写抛冲突；再之后恢复
  class FlakyPropStore < Troupe::PropStore
    def initialize(inner)
      @inner = inner
      @armed = false
    end

    def read(*args)
      @inner.read(*args)
    end

    def create(*args, **kw)
      @inner.create(*args, **kw)
    end

    def write(*args, **kw)
      if @armed
        @armed = false
        raise Troupe::ConflictError, "磁盘写入失败"
      end
      result = @inner.write(*args, **kw)
      @armed = true
      result
    end

    def delete(*args)
      @inner.delete(*args)
    end
  end

  def test_save_failure_invalidates_and_next_call_reloads_committed
    troupe = mk_troupe(actors: [CounterActor], prop_store: FlakyPropStore.new(Troupe::MemoryPropStore.new))
    cart = troupe.cast(CounterActor, "c1")
    cart.bump_commit(9) # 已提交 revision=2

    e = assert_raises(Troupe::ConflictError) { cart.bump_commit(1) } # 保存失败 → 冲突类错误
    assert_match(/磁盘写入失败/, e.message)

    # 实例失效：下次调用从最后已提交快照继续（不基于未提交状态运行）
    assert_equal 9, troupe.cast(CounterActor, "c1").value
    assert_equal 10, troupe.cast(CounterActor, "c1").bump_commit(1)
  end

  def test_intermission_off_stage_then_reactivation_with_restored_props
    store = Troupe::MemoryPropStore.new
    troupe = mk_troupe(actors: [CounterActor], prop_store: store, intermission: "0.15s")
    hook = Queue.new
    troupe.events.subscribe do |type, _|
      hook << type if type == :offstaged
    end

    cart = troupe.cast(CounterActor, "c1")
    cart.bump(42)
    assert_equal :offstaged, hook.pop # Intermission 到期自动下场
    wait_until { troupe.stage_manager.cell_count.zero? }

    # 下一条 Call 重新登台，Props 从 PropStore 恢复
    assert_equal 42, troupe.cast(CounterActor, "c1").value
  end

  def test_drain_all_saves_props
    store = Troupe::MemoryPropStore.new
    troupe = mk_troupe(actors: [CounterActor], prop_store: store)
    cart = troupe.cast(CounterActor, "d1")
    cart.bump(7)
    troupe.drain_all(timeout: 5)
    stored = store.read(troupe.config.namespace, "Counter", "d1")
    assert_equal 7, stored.props["n"]
  end

  class SlowGateActor < Troupe::Actor
    call_board_limit 2
    initial_props { { "seen" => [] } }

    def park
      props["seen"] << "park"
      GATE.pop # 测试控制放行
      "released"
    end

    def tick
      props["seen"] << "tick"
      "tick"
    end

    def seen
      props["seen"]
    end

    GATE = Queue.new
  end

  def test_call_board_full_rejects_with_backpressure
    troupe = mk_troupe(actors: [SlowGateActor])
    a = troupe.cast(SlowGateActor, "g1")

    first = Thread.new { a.park } # 占住串行通道
    # 等 park 真正开始执行（不再在 board 里），后续 tick 才是"排队"
    wait_until do
      detail = troupe.stage_manager.inspect_cell("SlowGate", "g1")
      detail && detail["props"] && detail["props"]["seen"] == ["park"]
    end

    q1 = Thread.new { a.tick } # 排队 1/2（调用方线程阻塞等 settle，属正常语义）
    q2 = Thread.new { a.tick } # 排队 2/2
    wait_until do
      detail = troupe.stage_manager.inspect_cell("SlowGate", "g1")
      detail && detail["callBoardDepth"] == 2
    end
    assert_raises(Troupe::BoardFullError) { a.tick } # 第 3 条排队被拒
    SlowGateActor::GATE << :go
    assert_equal "released", first.value
    assert_equal "tick", q1.value
    assert_equal "tick", q2.value
    assert_equal %w[park tick tick], a.seen
  end

  def test_activation_limit_backpressure
    troupe = mk_troupe(actors: [CounterActor], activation_limit: 2)
    agents = %w[a1 a2 a3].map { |n| troupe.cast(CounterActor, n) }
    errors = []
    concurrent(3) do |i|
      agents[i].bump(1)
    rescue Troupe::BackpressureError => e
      errors << e
    end
    assert_equal 1, errors.size, "激活数超限显式拒绝：恰好一个失败"
  end

  def test_local_call_copy_boundary
    troupe = mk_troupe(actors: [CounterActor])
    cart = troupe.cast(CounterActor, "c1")

    item = { "v" => [1, 2] }
    cart.stash(item) # 参数过 Codec 边界
    item["v"] << 999 # 调用方事后修改不影响 Actor

    snapshot = troupe.stage_manager.inspect_cell("Counter", "c1")["props"]["last"]
    assert_equal({ "v" => [1, 2] }, snapshot)
    refute_same item, snapshot
  end

  def test_whitelist_rejects_lifecycle_and_unknown
    troupe = mk_troupe(actors: [CounterActor])
    cart = troupe.cast(CounterActor, "c1")
    e = assert_raises(Troupe::UnknownMethodError) { cart.props }
    assert_match(/白名单/, e.message)
    assert_raises(Troupe::UnknownMethodError) { cart.on_stage }
    assert_raises(Troupe::UnknownMethodError) { cart.save_props }
    assert_raises(Troupe::UnknownMethodError) { cart.nope }
  end

  def test_role_conflict_fail_fast
    c1 = Class.new(Troupe::Actor) do
      role_id "dup"
      def x; end
    end
    c2 = Class.new(Troupe::Actor) do
      role_id "dup"
      def x; end
    end
    e = assert_raises(Troupe::RoleConflictError) { mk_troupe(actors: [c1, c2]) }
    assert_match(/dup/, e.message)
  end

  def test_kwargs_rejected_with_guidance
    troupe = mk_troupe(actors: [CounterActor])
    cart = troupe.cast(CounterActor, "c1")
    e = assert_raises(Troupe::SerializationError) { cart.bump(v: 1) }
    assert_match(/JSON 边界/, e.message)
  end
end
