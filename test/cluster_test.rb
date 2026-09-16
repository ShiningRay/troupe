# frozen_string_literal: true

require_relative "test_helper"

# 集群基础（PLAN M2/M3 验收）：TCP 组团、位置透明、线路边界、畸形帧可控拒绝、
# kill -9 级故障后 Actor 在另一 Stage 以完整 Props 重新登台（共享存储 + 所有权）。
class ClusterTest < Minitest::Test
  class WorkerActor < Troupe::Actor
    initial_props { { "n" => 0, "last" => nil } }

    def add(v = 1)
      props["n"] += v
      save_props
      props["n"]
    end

    def slow(ms)
      sleep(ms / 1000.0)
      "slow-ok"
    end

    def stash(x)
      props["last"] = x
      "stashed"
    end

    def value
      props["n"]
    end
  end

  def setup
    @troupes = []
  end

  def teardown
    @troupes.each { |t| t.shutdown! rescue nil }
  end

  def form_troupe(**opts)
    troupe = Troupe.form({ actors: [WorkerActor], prop_store: Troupe::MemoryPropStore.new,
                           port: 0, join_timeout: "5s" }.merge(opts))
    @troupes << troupe
    troupe
  end

  def test_two_stages_join_and_route_transparently
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    wait_until { t2.roster.alive_peers.include?(t1.advertise) }

    # 选一个环上归属 t2 的 key，从 t1 发起调用：位置透明
    key = (0..50).find { |i| t1.playbill.owner_address("troupe", "Worker", "k#{i}") == t2.advertise }
    refute_nil key, "哈希环应把某些 key 分给 t2"
    agent = t1.cast(WorkerActor, "k#{key}")
    assert_equal 1, agent.add(1)
    assert_equal 2, agent.add(1) # 两次都落到 t2 的同一 Cell（严格串行）
    assert_equal 0, t1.stage_manager.cell_count, "调用方 Stage 不持有该 Actor"
    assert_equal 1, t2.stage_manager.cell_count
  end

  def test_wire_json_boundary_same_as_local
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }

    key = (0..50).find { |i| t1.playbill.owner_address("troupe", "Worker", "w#{i}") == t2.advertise }
    agent = t1.cast(WorkerActor, "w#{key}")
    symbol_hash = { :name => :x } # Symbol 经线路 → String（JSON 边界语义，与本地一致）
    agent.stash(symbol_hash)
    assert_equal({ "name" => "x" }, troupe_props_of(t2, "Worker", "w#{key}")["last"])
  end

  def test_remote_deadline_and_result_unknown
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    key = (0..50).find { |i| t1.playbill.owner_address("troupe", "Worker", "d#{i}") == t2.advertise }
    agent = t1.cast(WorkerActor, "d#{key}")

    e = assert_raises(Troupe::CallTimeoutError) do
      agent.with_timeout("0.2s").slow(600)
    end
    assert_match(/结果未知/, e.message) # 远程超时同样是结果未知，不是失败
  end

  def test_whitelist_enforced_on_wire
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    wait_until { t2.roster.alive_peers.include?(t1.advertise) } # 视图收敛，环归属一致

    # 直接构造线路帧调用生命周期钩子：接收端白名单拒绝（信任边界，DESIGN §6.1）
    call = Troupe::Call.new(namespace: "troupe", role_id: "Worker", stage_name: "evil",
                            method: :on_stage, args: [],
                            deadline_ms: Troupe::Util.now_ms + 3000, source: :remote)
    e = assert_raises(Troupe::UnknownMethodError) { t2.dispatch_inbound(call) }
    assert_match(/白名单/, e.message)
  end

  def test_malformed_frame_rejected_connection_and_process_survive
    t1 = form_troupe
    host, port = t1.advertise.split(":")

    sock = TCPSocket.new(host, port)
    sock.write([16].pack("V") + "not-json-goop!!")
    sock.close

    # 超长帧
    sock2 = TCPSocket.new(host, port)
    sock2.write([Troupe::Transport::FRAME_MAX + 1].pack("V"))
    sock2.close

    # 进程与 Stage 存活，后续调用正常
    a = t1.cast(WorkerActor, "local-ok")
    assert_equal 1, a.add(1)
  end

  # M3 验收：kill -9 一个 Stage，Actor 在存活 Stage 以完整 Props 重新登台（共享存储）
  def test_stage_death_failover_with_shared_store_and_fencing
    store = Troupe::MemoryPropStore.new(ownership: true)
    # 短租约：真实接管需等旧 Stage 租约到期（心跳随进程一起死亡）
    t1 = form_troupe(prop_store: store, ownership_lease: "1s")
    t2 = form_troupe(prop_store: store, seeds: [t1.advertise], ownership_lease: "1s")
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }

    key = (0..50).find { |i| t1.playbill.owner_address("troupe", "Worker", "f#{i}") == t2.advertise }
    agent = t1.cast(WorkerActor, "f#{key}")
    assert_equal 3, 3.times.map { agent.add(1) }.last # 在 t2 上激活并提交

    # kill -9 等价：t2 整个运行时瞬间消失（传输 + 所有权心跳 + 调度器全部停止）
    dead_incarnation = t2.roster.self_incarnation
    t2.shutdown!(grace: "0.2s")
    t1.roster.merge([{ "addr" => t2.advertise, "incarnation" => dead_incarnation, "status" => "dead",
                       "roles" => [], "protocol" => 1 }])
    wait_until { t1.playbill.owner_address("troupe", "Worker", "f#{key}") == t1.advertise }
    # 环上归我之后还需等旧租约到期才能接管（所有权激活前置，DESIGN §6.5）
    agent2 = nil
    wait_until(15) do
      agent2 = t1.cast(WorkerActor, "f#{key}")
      begin
        agent2.add(0) # 触发激活（可能先等所有权）
        true
      rescue Troupe::OwnershipError
        false
      end
    end

    # 后续 Call 在 t1 重新登台：Props 从共享存储恢复
    assert_equal 4, agent2.add(1)
    detail = t1.stage_manager.inspect_cell("Worker", "f#{key}")
    assert_equal 2, detail["fencingToken"], "接管后 epoch 单调递增"

    # 旧 Stage（若复活）的旧 token 写入会被拒绝
    stored = store.read("troupe", "Worker", "f#{key}")
    assert_raises(Troupe::ConflictError) do
      store.write("troupe", "Worker", "f#{key}", stored.props.merge("n" => 999),
                  expected_revision: stored.revision, schema_version: 1, fencing_token: 1)
    end
  end

  def test_forward_hop_limit
    t1 = form_troupe
    t2 = form_troupe(seeds: [t1.advertise])
    wait_until { t1.roster.alive_peers.include?(t2.advertise) }
    key = (0..50).find { |i| t1.playbill.owner_address("troupe", "Worker", "h#{i}") == t2.advertise }

    # 已带 2 跳的转发请求再进 t1（环漂移场景）→ 显式拒绝，防环（DESIGN §6.3）
    call = Troupe::Call.new(namespace: "troupe", role_id: "Worker", stage_name: "h#{key}",
                            method: :value, args: [],
                            deadline_ms: Troupe::Util.now_ms + 3000, source: :remote, hop: 2)
    e = assert_raises(Troupe::CallRejectedError) { t1.dispatch_inbound(call) }
    assert_match(/跳数上限/, e.message)
  end

  private

  def troupe_props_of(troupe, role, name)
    troupe.stage_manager.inspect_cell(role, name)["props"]
  end
end
