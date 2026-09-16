# frozen_string_literal: true

require_relative "test_helper"

# Cue 与持久提醒（DESIGN §3.3/§7.5，PLAN M4 验收）：
# 下场后提醒按时触发并重新登台；执行一半宕机 → 租约到期重新投递（至少一次）。
class CueTest < Minitest::Test
  def teardown
    @troupes&.each { |t| t.shutdown! rescue nil }
  end

  def form_troupe(**opts)
    troupe = Troupe::Testing.rehearsal(**opts)
    (@troupes ||= []) << troupe
    troupe
  end

  class TickerActor < Troupe::Actor
    initial_props { { "ticks" => 0 } }

    def arm_cue
      register_cue("tick", "0.1s") { tick }
    end

    def tick
      props["ticks"] += 1
    end

    def ticks
      props["ticks"]
    end
  end

  def test_in_memory_cue_fires_and_dies_with_instance
    troupe = form_troupe(actors: [TickerActor])
    a = troupe.cast(TickerActor, "t1")
    a.arm_cue
    wait_until { a.ticks >= 3 }

    troupe.drain_all(timeout: 5) # 下场：Cue 随实例消失；框架排空保存使内存计数落盘
    wait_until { troupe.stage_manager.cell_count.zero? }

    # 重新登台：Props 恢复（含被排空保存的计数），但内存 Cue 不再自动触发
    fresh = troupe.cast(TickerActor, "t1")
    count = fresh.ticks
    assert_operator count, :>=, 3
    sleep 0.35
    assert_equal count, fresh.ticks, "内存 Cue 不应再触发（Cue 随实例下场消失）"
  end

  class ReminderActor < Troupe::Actor
    initial_props { { "fires" => 0, "slow_done" => false, "slow_enabled" => false } }

    def on_stage
      # 每次 on_stage 重复注册是幂等的（upsert 只更新定义、不动 next_due）
      schedule_reminder("beat", "0.2s", payload: { "kind" => "beat" })
    end

    def on_cue(name, payload)
      props["fires"] += 1
      if !props["slow_done"] && props["slow_enabled"]
        props["slow_done"] = true
        sleep 0.6 # 执行一半"宕机"：租约到期 → 重新投递（至少一次）
      end
      save_props
      props["fires"]
    end

    def enable_slow
      props["slow_enabled"] = true
      save_props
    end

    def fire_count
      props["fires"]
    end

    def cancel
      cancel_reminder("beat")
    end
  end

  def test_persistent_reminder_reactivates_after_off_stage
    troupe = form_troupe(actors: [ReminderActor], intermission: "0.15s", cue_tick: "0.05s")
    troupe.cast(ReminderActor, "r1").enable_slow
    wait_until { troupe.stage_manager.cell_count.zero? } # 先下场

    # 提醒触发 → 重新登台（多次），哪怕 Actor 不在场（PLAN M4 验收）
    wait_until(8) { troupe.cast(ReminderActor, "r1").fire_count >= 3 }
  end

  def test_at_least_once_redelivery_after_lease_expiry
    troupe = form_troupe(actors: [ReminderActor], cue_tick: "0.05s", reminder_lease: "0.3s")
    a = troupe.cast(ReminderActor, "r2")
    a.enable_slow # 第一次 on_cue 睡 0.6s > 租约 0.3s → 重新认领重投

    wait_until(10) { troupe.cast(ReminderActor, "r2").fire_count >= 2 }
    assert_operator troupe.cast(ReminderActor, "r2").fire_count, :>=, 2, "租约到期重新投递（至少一次）"
  end

  def test_reminder_cancel
    troupe = form_troupe(actors: [ReminderActor], cue_tick: "0.05s")
    a = troupe.cast(ReminderActor, "r3")
    a.fire_count # 激活（on_stage 注册提醒）
    wait_until { troupe.cue_store.list.size >= 1 } # 注册完成
    a.cancel
    wait_until { troupe.cue_store.list.empty? }
    count = troupe.cast(ReminderActor, "r3").fire_count
    sleep 0.5
    assert_equal count, troupe.cast(ReminderActor, "r3").fire_count, "注销后不再投递"
  end

  def test_missed_periods_skip_not_catch_up_burst
    troupe = form_troupe(actors: [ReminderActor], cue_tick: "0.05s")
    wait_until(10) { troupe.cast(ReminderActor, "r5").fire_count >= 2 }
    first = troupe.cast(ReminderActor, "r5").fire_count
    sleep 1.0
    grown = troupe.cast(ReminderActor, "r5").fire_count - first
    assert_operator grown, :<=, 7, "错过多个周期默认跳过，不补发风暴（1s 内 ≤7 次）"
  end
end
