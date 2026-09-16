# frozen_string_literal: true

require_relative "test_helper"

# Director 系统角色（DESIGN §11.1，PLAN M4 验收）：内省、管理调用受白名单约束、扇出聚合
class DirectorTest < Minitest::Test
  class CartActor < Troupe::Actor
    initial_props { { "items" => [] } }

    def add(item)
      props["items"] << item
      save_props
      props["items"].size
    end

    def items
      props["items"]
    end
  end

  def setup
    @troupes = []
  end

  def teardown
    @troupes.each { |t| t.shutdown! rescue nil }
  end

  def form_troupe(**opts)
    troupe = Troupe.form({ actors: [CartActor], prop_store: Troupe::MemoryPropStore.new, port: 0 }.merge(opts))
    @troupes << troupe
    troupe
  end

  def test_status_and_actors
    troupe = form_troupe
    status = troupe.director.handle("status")
    assert_equal troupe.advertise, status["stage"]
    assert_equal ["Cart"], status["roles"]
    assert_equal 0, status["actorsOn"]

    troupe.cast(CartActor, "u1").add("x")
    actors = troupe.director.handle("actors")
    assert_equal 1, actors.size
    assert_equal "u1", actors[0]["stageName"]
    assert_equal "running", actors[0]["state"]
  end

  def test_inspect_shows_props_snapshot
    troupe = form_troupe
    troupe.cast(CartActor, "u1").add({ "sku" => "a" })
    detail = troupe.director.handle("inspect", ["Cart", "u1"])
    assert_equal [{ "sku" => "a" }], detail["props"]["items"]
    assert_raises(Troupe::CallRejectedError) { troupe.director.handle("inspect", ["Cart", "absent"]) }
  end

  def test_invoke_goes_through_whitelist
    troupe = form_troupe
    n = troupe.director.handle("invoke", ["Cart", "u1", "add", [{ "sku" => "b" }]])
    assert_equal 1, n

    # 生命周期钩子不可经 invoke 调用（信任边界）
    e = assert_raises(Troupe::UnknownMethodError) do
      troupe.director.handle("invoke", ["Cart", "u1", "on_stage", []])
    end
    assert_match(/白名单/, e.message)
  end

  def test_off_removes_from_ps
    troupe = form_troupe
    troupe.cast(CartActor, "u1").add("x")
    assert_equal 1, troupe.stage_manager.cell_count

    result = troupe.director.handle("off", ["Cart", "u1"])
    assert_equal true, result["off"]
    wait_until { troupe.stage_manager.cell_count.zero? }

    # 下场后 Props 已保存：再来一条 Call 重新登台并恢复
    assert_equal 1, troupe.cast(CartActor, "u1").items.size
  end

  def test_remote_director_call_and_cluster_fanout
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }

    # 瘦客户端语义：跨 Stage 的 Director 调用直达对端
    status = t1.transport.director_call(t2.advertise, "status", [])
    assert_equal t2.advertise, status["stage"]

    t2.cast(CartActor, "remote-1").add("y")
    actors = t1.director.handle("actors", [true]) # 扇出聚合（ps 数据源）
    names = actors.map { |a| a["stageName"] }
    assert_includes names, "remote-1", "集群聚合能看到另一 Stage 的在场演员"
  end

  def test_trace_bus_records_calls
    troupe = form_troupe
    troupe.cast(CartActor, "u1").add("x")
    wait_until { troupe.trace.size >= 1 }
    events = troupe.trace.recent(10)
    ev = events.find { |e| e["method"] == "add" }
    refute_nil ev
    assert_equal "Cart", ev["role"]
    assert_equal "ok", ev["outcome"]
    assert_operator ev["durationMs"], :>=, 0
  end
end
