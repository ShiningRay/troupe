# frozen_string_literal: true

require_relative "test_helper"

class CodecTest < Minitest::Test
  def test_primitives_pass_through
    assert_same Troupe::Codec.copy(1), 1
    assert_same Troupe::Codec.copy(nil), nil
    assert_equal "s", Troupe::Codec.copy("s")
    # 字符串走 JSON round-trip：内容恒等
    assert_equal "中文", Troupe::Codec.copy("中文")
  end

  def test_copy_isolates_mutables
    original = { "a" => [{ "b" => 1 }] }
    copied = Troupe::Codec.copy(original)
    copied["a"][0]["b"] = 999
    assert_equal 1, original["a"][0]["b"]
  end

  def test_symbol_normalized_to_string_both_keys_and_values
    src = { :name => :cart, 1 => :x }
    out = Troupe::Codec.copy(src)
    assert_equal({ "name" => "cart", "1" => "x" }, out)
  end

  def test_time_becomes_iso_string
    t = Time.utc(2026, 9, 12, 8, 0, 0)
    assert_equal "2026-09-12T08:00:00.000000Z", Troupe::Codec.copy(t)
  end

  def test_bigint_survives_ruby_json
    big = 2**70
    assert_equal big, Troupe::Codec.copy(big) # Ruby 无 JS BigInt 精度问题
  end

  def test_cycle_raises_with_guidance
    a = {}
    a["self"] = a
    e = assert_raises(Troupe::SerializationError) { Troupe::Codec.copy(a) }
    assert_match(/循环引用/, e.message)
    assert_match(/DTO/, e.message)
  end

  def test_unsupported_type_raises
    obj = Object.new
    e = assert_raises(Troupe::SerializationError) { Troupe::Codec.copy(obj) }
    assert_match(/Object/, e.message)
  end

  def test_shared_reference_dag_allowed
    shared = [1]
    out = Troupe::Codec.copy({ "a" => shared, "b" => shared })
    assert_equal [1], out["a"]
    assert_equal [1], out["b"]
  end
end

class Xxh32Test < Minitest::Test
  def test_known_vectors
    assert_equal 0x02CC5D05, Troupe::Xxh32.digest("")
    assert_equal 0x550D7456, Troupe::Xxh32.digest("a")
    assert_equal 0x32D153FF, Troupe::Xxh32.digest("abc")
  end

  def test_seed_and_determinism
    assert_equal Troupe::Xxh32.digest("hello"), Troupe::Xxh32.digest("hello")
    assert_equal Troupe::Xxh32.digest("hello", 7), Troupe::Xxh32.digest("hello", 7)
    refute_equal Troupe::Xxh32.digest("hello"), Troupe::Xxh32.digest("hello", 1)
  end

  def test_32bit_range_and_distribution
    buckets = Array.new(8, 0)
    2000.times do |i|
      h = Troupe::Xxh32.digest("key-#{i}")
      assert_operator h, :<=, 0xFFFF_FFFF
      buckets[h % 8] += 1
    end
    # 分布粗检：无空桶、无巨桶（xxh32 的基本质量）
    buckets.each { |b| assert_in_delta 250, b, 150 }
  end
end

class HashRingTest < Minitest::Test
  def setup
    @ring = Troupe::HashRing.new
    %w[a b c].each { |n| @ring.add_node(n) }
  end

  def test_lookup_stable_and_member_of_ring
    100.times do |i|
      node = @ring.get_node("ns:Cart:user-#{i}")
      assert_includes %w[a b c], node
      assert_equal node, @ring.get_node("ns:Cart:user-#{i}") # 稳定
    end
  end

  def test_add_node_moves_minimal_keys
    before = 300.times.map { |i| @ring.get_node("k#{i}") }
    @ring.add_node("d")
    moved = 300.times.count { |i| before[i] != @ring.get_node("k#{i}") }
    # 一致性哈希：新增节点约迁移 1/4 的键（允许波动）
    assert_operator moved, :<, 150, "迁移键过多：#{moved}/300"
    assert_operator moved, :>, 20, "迁移键过少：#{moved}/300"
  end

  def test_remove_node
    @ring.remove_node("b")
    100.times { |i| assert_includes %w[a c], @ring.get_node("k#{i}") }
  end

  def test_virtual_nodes_balanced
    dist = @ring.distribution
    assert_equal %w[a b c], dist.keys.sort
    dist.each_value { |v| assert_in_delta 160, v, 40 } # 每 Stage 160 vnodes
  end

  def test_empty_ring_returns_nil
    assert_nil Troupe::HashRing.new.get_node("x")
  end
end

class RosterMergeTest < Minitest::Test
  StubRepertoire = Struct.new(:role_ids)

  def stub_troupe(addr)
    Struct.new(:advertise, :repertoire).new(addr, StubRepertoire.new([]))
  end

  def setup
    @roster = Troupe::Roster.new(stub_troupe("127.0.0.1:1"))
  end

  def rec(addr, inc, status)
    { "addr" => addr, "incarnation" => inc, "status" => status, "roles" => [], "protocol" => 1 }
  end

  def test_new_member_adopted_and_ring_view_includes_it
    @roster.merge([rec("127.0.0.1:2", "100-a", "alive")])
    assert_includes @roster.view[:addresses], "127.0.0.1:2"
  end

  def test_stale_alive_cannot_revive_dead
    @roster.merge([rec("127.0.0.1:2", "100-a", "dead")])
    @roster.merge([rec("127.0.0.1:2", "100-a", "alive")]) # 反复转发的旧 alive
    member = @roster.view[:addresses]
    refute_includes member, "127.0.0.1:2", "dead 是终态，不能被同 incarnation 复活"
  end

  def test_new_incarnation_wins
    @roster.merge([rec("127.0.0.1:2", "100-a", "dead")])
    @roster.merge([rec("127.0.0.1:2", "200-b", "alive")]) # 重启 = 新身份
    assert_includes @roster.view[:addresses], "127.0.0.1:2"
  end

  def test_alive_gossip_refutes_suspect
    @roster.merge([rec("127.0.0.1:2", "100-a", "alive")])
    @roster.merge([rec("127.0.0.1:2", "100-a", "suspect")])
    # suspect 不摘环（确认 dead 才摘），但状态已退化
    assert_equal "suspect", @roster.stage_infos.find { |s| s["addr"] == "127.0.0.1:2" }["status"]
    @roster.refute("127.0.0.1:2") # 探测 ACK 反驳
    assert_equal "alive", @roster.stage_infos.find { |s| s["addr"] == "127.0.0.1:2" }["status"]
  end

  def test_self_never_merged
    @roster.merge([rec("127.0.0.1:1", "999-z", "dead")])
    assert_includes @roster.view[:addresses], "127.0.0.1:1"
  end
end

class CronTest < Minitest::Test
  def test_daily_at_9
    from = Time.new(2026, 9, 12, 10, 0, 0)
    nxt = Troupe::Cron.next_after("0 9 * * *", from)
    assert_equal Time.new(2026, 9, 13, 9, 0, 0), nxt
  end

  def test_every_five_minutes
    from = Time.new(2026, 9, 12, 10, 3, 0)
    nxt = Troupe::Cron.next_after("*/5 * * * *", from)
    assert_equal Time.new(2026, 9, 12, 10, 5, 0), nxt
  end

  def test_weekday_names_and_list
    from = Time.new(2026, 9, 12, 8, 0, 0) # 周六
    nxt = Troupe::Cron.next_after("30 9 * * mon-fri", from)
    assert_equal Time.new(2026, 9, 14, 9, 30, 0), nxt # 下周一
  end

  def test_dom_dow_or_semantics
    # 13 号 或 周一 —— vixie cron：两者都受限时取或
    # 2026-09-12 是周六；9/13（周日）命中 dom，先于下周一 9/14
    from = Time.new(2026, 9, 12, 8, 0, 0)
    nxt = Troupe::Cron.next_after("0 0 13 * mon", from)
    assert_equal Time.new(2026, 9, 13, 0, 0, 0), nxt
  end

  def test_month_names
    from = Time.new(2026, 9, 12, 8, 0, 0)
    nxt = Troupe::Cron.next_after("0 0 1 jan *", from)
    assert_equal Time.new(2027, 1, 1, 0, 0, 0), nxt
  end

  def test_invalid_expr_raises
    assert_raises(ArgumentError) { Troupe::Cron.parse!("* * * *") }
    assert_raises(ArgumentError) { Troupe::Cron.parse!("61 * * * *") }
  end
end
