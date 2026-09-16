# frozen_string_literal: true

require_relative "../errors"
require_relative "../util"
require_relative "cue_store"

module Troupe
  # Cue 调度器（DESIGN §7.5）：每 Stage 一个 tick 线程。
  # due() 发现 → claim() 在多个 Stage 间分配执行责任 → on_cue 作为一条 Call
  # 进入 CallBoard（受同一调度约束）→ complete() 以 statusVersion 裁决。
  # 至少一次投递：执行中宕机 → 租约到期被重新认领、重复投递。
  class CueScheduler
    BATCH = 64

    attr_reader :troupe, :store

    def initialize(troupe, store)
      @troupe = troupe
      @store = store
      @tick = Util.parse_duration(troupe.config.cue_tick, "cue tick")
      @lease_ms = (Util.parse_duration(troupe.config.reminder_lease, "提醒租约") * 1000).to_i
      @stopped = false
      @sleeper = Util::Sleeper.new
      @thread = nil
    end

    def start
      @thread = Thread.new do
        begin
          Thread.current.name = "troupe-cues"
        rescue StandardError
          nil
        end
        loop do
          break if @sleeper.sleep(@tick)
          break if @stopped

          tick
        end
      rescue StandardError => e
        Log.error("cue 调度线程退出：#{e.class}: #{e.message}")
      end
    end

    def stop
      @stopped = true
      @sleeper.cancel
      @thread&.join(1)
    end

    def tick
      now = Util.now_ms
      records = store.due(now, BATCH)
      records.each do |rec|
        next if rec.namespace != @troupe.config.namespace # 多 Troupe 共享存储时只管自己的命名空间

        version = store.claim(rec.id, owner: @troupe.owner_id, lease_until: now + @lease_ms)
        next unless version

        # 认领成功即负责投递；投递异步化，不阻塞同一 tick 的其他提醒
        Thread.new(rec, version) { |r, v| deliver(r, v) }
      end
    rescue StandardError => e
      Log.error("cue tick 异常：#{e.class}: #{e.message}")
    end

    def deliver(rec, claimed_version)
      call = Call.new(
        namespace: rec.namespace, role_id: rec.role_id, stage_name: rec.stage_name,
        method: :on_cue, args: [rec.name, rec.payload],
        deadline_ms: Util.now_ms + (Util.parse_duration(@troupe.config.call_timeout, "超时") * 1000).to_i,
        source: :reminder, internal: true
      )
      begin
        @troupe.route(call) # 位置透明：不在场则重新登台，可能经环转发到归属 Stage
      rescue StandardError => e
        Log.warn("提醒 #{rec.id} 投递失败（#{e.class}: #{e.message}）：租约到期将重投（至少一次）")
        return
      end
      next_due = CueStore.compute_next(rec.schedule, Util.now_ms)
      complete(rec, claimed_version, next_due)
    end

    def complete(rec, claimed_version, next_due)
      # 错过多个周期：默认跳过并按当前时刻计算下一次（跳过补发一次已由本次投递完成）
      ok = store.complete(rec.id, expected_status_version: claimed_version, next_due: next_due)
      Log.warn("提醒 #{rec.id} 完成 CAS 失败：已被注销或被重新投递裁决（statusVersion 竞争）") unless ok
    end

    # Actor 端注册入口（Cell#schedule_reminder 委托到这里）
    def upsert_from_actor(namespace, role_id, stage_name, name, spec, payload)
      schedule = CueStore.normalize_schedule(spec)
      id = Util.new_id(namespace, role_id, stage_name, name)
      now = Util.now_ms
      existing = store.find(id)
      next_due = existing ? existing.next_due : CueStore.compute_next(schedule, now)
      store.upsert(ReminderRecord.new(
                     id: id, namespace: namespace, role_id: role_id, stage_name: stage_name,
                     name: name, payload: Codec.copy(payload || nil), schedule: schedule, next_due: next_due
                   ))
      Log.debug("持久提醒已注册：#{id} schedule=#{schedule} next_due=#{Time.at(next_due / 1000.0)}")
      id
    end
  end
end
