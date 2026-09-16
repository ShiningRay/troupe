# frozen_string_literal: true

require_relative "test_helper"

# 所有权契约（DESIGN §6.5）：租约 + 单调 epoch + fencing token + 交接
class OwnershipTest < Minitest::Test
  class CounterActor < Troupe::Actor
    initial_props { { "n" => 0 } }

    def bump(v = 1)
      props["n"] += v
      save_props
      props["n"]
    end

    def value
      props["n"]
    end
  end

  def test_acquire_renew_release
    store = Troupe::MemoryPropStore.new(ownership: true)
    now = Troupe::Util.now_ms
    r1 = store.acquire_ownership("ns", "C", "u", owner: "A", lease_ms: 60_000)
    assert_equal 1, r1.epoch
    r2 = store.acquire_ownership("ns", "C", "u", owner: "A", lease_ms: 60_000)
    assert_equal 1, r2.epoch, "同 owner 续持不涨 epoch"
    assert_nil store.acquire_ownership("ns", "C", "u", owner: "B", lease_ms: 60_000), "他人持有效租约时取不到"

    # 租约到期被顶替：新 epoch > 旧
    store.ownership_record("ns", "C", "u")[:lease_until] = now - 1
    r3 = store.acquire_ownership("ns", "C", "u", owner: "B", lease_ms: 60_000)
    assert_equal 2, r3.epoch

    # 旧持有者的续租与释放都被拒绝（expected_epoch 不匹配）
    refute store.renew_ownership("ns", "C", "u", owner: "A", expected_epoch: 1, lease_ms: 60_000)
    store.release_ownership("ns", "C", "u", owner: "A", expected_epoch: 1)
    assert_equal "B", store.ownership_record("ns", "C", "u")[:owner]
  end

  def test_takeover_rejects_old_owner_writes_fencing
    store = Troupe::MemoryPropStore.new(ownership: true)
    troupe_a = Troupe::Testing.rehearsal(actors: [CounterActor], prop_store: store, ownership_acquire_timeout: "0.2s")
    troupe_b = Troupe::Testing.rehearsal(actors: [CounterActor], prop_store: store, ownership_acquire_timeout: "0.2s")

    a = troupe_a.cast(CounterActor, "shared-1")
    assert_equal 5, a.bump(5)
    assert_equal 1, troupe_a.stage_manager.inspect_cell("Counter", "shared-1")["fencingToken"]

    # 顶替：把租约拨到过期，B 抢到 epoch 2
    store.ownership_record("troupe", "Counter", "shared-1")[:lease_until] = Troupe::Util.now_ms - 1
    b = troupe_b.cast(CounterActor, "shared-1")
    assert_equal 5, b.value # B 触发激活，以完整 Props 重新登台
    assert_equal 2, troupe_b.stage_manager.inspect_cell("Counter", "shared-1")["fencingToken"]

    # 旧实例 A 的后续保存被存储拒绝（fencing）→ A 调用方收到 ConflictError
    e = assert_raises(Troupe::ConflictError) { a.bump(100) }
    assert_match(/fencing token 过期/, e.message)

    # B 不受影响；A 已失效，下次调用等待/重新获取（当前被 B 持有 → B 的数据一致）
    assert_equal 6, b.bump(1)
    assert_equal 6, troupe_b.cast(CounterActor, "shared-1").value

    troupe_a.shutdown!
    troupe_b.shutdown!
  end

  def test_activation_waits_and_times_out_when_lease_held
    store = Troupe::MemoryPropStore.new(ownership: true)
    troupe_a = Troupe::Testing.rehearsal(actors: [CounterActor], prop_store: store)
    troupe_b = Troupe::Testing.rehearsal(actors: [CounterActor], prop_store: store,
                                         ownership_acquire_timeout: "0.2s")
    troupe_a.cast(CounterActor, "held").bump(1)

    e = assert_raises(Troupe::OwnershipError) do
      troupe_b.cast(CounterActor, "held").bump(1)
    end
    assert_match(/等待所有权超时/, e.message)

    troupe_a.shutdown!
    troupe_b.shutdown!
  end

  def test_takeover_after_lease_expiry_reactivates_on_b
    store = Troupe::MemoryPropStore.new(ownership: true)
    a = Troupe::Testing.rehearsal(actors: [CounterActor], prop_store: store)
    b = Troupe::Testing.rehearsal(actors: [CounterActor], prop_store: store, ownership_acquire_timeout: "1s")
    a.cast(CounterActor, "x").bump(7)

    store.ownership_record("troupe", "Counter", "x")[:lease_until] = Troupe::Util.now_ms - 1
    assert_equal 7, b.cast(CounterActor, "x").value # B 以完整 Props 重新登台

    a.shutdown!
    b.shutdown!
  end
end
