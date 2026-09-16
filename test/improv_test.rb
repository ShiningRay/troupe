# frozen_string_literal: true

require_relative "test_helper"

# 交错执行（DESIGN §5.4 / PLAN M5）：组合矩阵 + 写饥饿防护
# Ruby 适配：annotated 调度到独立线程（GVL 在 I/O 等待点让出），
# strict 仍由单调度线程独占——组合矩阵语义与 Troupe.js 一致。
class ImprovTest < Minitest::Test
  class SessionActor < Troupe::Actor
    initial_props { { "timeline" => [], "reads" => 0 } }

    improv :slow_improv
    read_only :slow_read, :peek

    def slow_improv(ms = 200)
      props["timeline"] << "improv-start"
      sleep(ms / 1000.0)
      props["timeline"] << "improv-end"
      "improv"
    end

    def slow_read(ms = 200)
      props["timeline"] << "read-start"
      sleep(ms / 1000.0)
      props["timeline"] << "read-end"
      "read"
    end

    def strict(ms = 200)
      props["timeline"] << "strict-start"
      sleep(ms / 1000.0)
      props["timeline"] << "strict-end"
      "strict"
    end

    def peek
      props["reads"] += 1
      "peek"
    end

    def timeline
      props["timeline"]
    end
  end

  def setup
    @troupe = Troupe::Testing.rehearsal(actors: [SessionActor])
  end

  def teardown
    @troupe.shutdown! rescue nil
  end

  def test_annotated_annotated_interleave
    a = @troupe.cast(SessionActor, "s1")
    t0 = Troupe::Util.mono
    t1 = Thread.new { a.slow_improv(250) }
    t2 = Thread.new { a.slow_read(250) }
    t1.join
    t2.join
    elapsed = Troupe::Util.mono - t0
    assert_operator elapsed, :<, 0.45, "annotated × annotated 交错执行（并发完成，#{(elapsed * 1000).round}ms）"
  end

  def test_strict_excludes_everything
    a = @troupe.cast(SessionActor, "s2")
    strict_thread = Thread.new { a.strict(200) }
    sleep 0.05 # strict 已在飞

    t0 = Troupe::Util.mono
    a.slow_improv(50) # annotated 只能等 strict settle
    waited = Troupe::Util.mono - t0
    assert_operator waited, :>=, 0.12, "未标注在飞时 annotated 不启动"

    strict_thread.join
    tl = a.timeline
    assert_equal "strict-start", tl[0]
    assert_equal "strict-end", tl[1], "strict 独占：期间无交错"
    assert_equal "improv-start", tl[2]
  end

  def test_write_starvation_guard_strict_queued_blocks_new_annotated
    a = @troupe.cast(SessionActor, "s3")
    improv_fiber = Thread.new { a.slow_improv(250) } # 在飞 annotated
    sleep 0.05

    strict_result = Thread.new { a.strict(80) } # strict 入队：写饥饿防护开始
    sleep 0.02
    t0 = Troupe::Util.mono
    a.peek # 新 annotated 请求：须等 strict 完成后才开始
    peek_waited = Troupe::Util.mono - t0
    assert_operator peek_waited, :>=, 0.15, "strict 入队后停止启动新 annotated（写等待有界）"

    improv_fiber.join
    strict_result.join
    tl = a.timeline
    assert_equal "improv-start", tl[0]
    assert_equal %w[improv-start improv-end strict-start strict-end], tl.first(4)
  end

  def test_strict_fifo_order
    a = @troupe.cast(SessionActor, "s4")
    order = Queue.new
    threads = Array.new(5) { |i| Thread.new { a.strict(10); order << i } }
    threads.each(&:join)
    results = 5.times.map { order.pop }
    assert_equal [0, 1, 2, 3, 4], results, "strict 启动按 FIFO"
  end

  def test_quiesce_waits_all_in_flight
    a = @troupe.cast(SessionActor, "s5")
    t1 = Thread.new { a.slow_improv(300) }
    t2 = Thread.new { a.slow_read(300) }
    sleep 0.1
    done = @troupe.quiesce(timeout: 3)
    assert done, "quiesce 等待全部在飞 Turn（含 annotated）"
    assert_includes a.timeline, "improv-end"
    assert_includes a.timeline, "read-end"
    t1.join
    t2.join
  end

  def test_annotation_requires_existing_method
    bad = Class.new(Troupe::Actor) do
      role_id "badanno"
      improv :nonexistent
    end
    # 校验延迟到注册时（DSL 顺序自由），form() 仍尽早报错（DESIGN §1.3）
    e = assert_raises(Troupe::ConfigError) do
      Troupe::Testing.rehearsal(actors: [bad])
    end
    assert_match(/不存在/, e.message)
  end
end
