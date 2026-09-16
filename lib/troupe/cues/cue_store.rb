# frozen_string_literal: true

require_relative "../errors"
require_relative "../util"
require_relative "cron"

module Troupe
  # 持久提醒记录（DESIGN §7.5）：稳定名称 + 可序列化负载 + 计划/nextDue/statusVersion。
  # 不持久化闭包——以 name + payload 经 on_cue(name, payload) 分派。
  class ReminderRecord
    attr_accessor :id, :namespace, :role_id, :stage_name, :name, :payload,
                  :schedule, :next_due, :status_version, :status, :owner, :lease_until

    def initialize(id:, namespace:, role_id:, stage_name:, name:, payload:,
                   schedule:, next_due:, status_version: 0, status: "active", owner: nil, lease_until: nil)
      @id = id
      @namespace = namespace
      @role_id = role_id
      @stage_name = stage_name
      @name = name
      @payload = payload
      @schedule = schedule
      @next_due = next_due
      @status_version = status_version
      @status = status
      @owner = owner
      @lease_until = lease_until
    end

    def to_h
      {
        "id" => @id, "namespace" => @namespace, "role" => @role_id, "stageName" => @stage_name,
        "name" => @name, "payload" => @payload, "schedule" => @schedule,
        "nextDue" => @next_due, "statusVersion" => @status_version, "status" => @status
      }
    end
  end

  # CueStore（提词存档）接口 + Memory 实现（DESIGN §7.5）：
  # 到期查询 / 原子 claim（租约）/ 完成确认（statusVersion CAS）/ 注销。
  # 投递语义：至少一次 + 业务幂等（不承诺恰好一次）。
  class CueStore
    def upsert(_record)
      raise NotImplementedError
    end

    def find(_id)
      raise NotImplementedError
    end

    # 到期查询：active 且到期，或 running 但租约已过期（执行中宕机 → 重新投递）
    def due(_now, _limit)
      raise NotImplementedError
    end

    # 原子认领：返回认领后的 status_version；争用失败返回 nil
    def claim(_id, owner:, lease_until:)
      raise NotImplementedError
    end

    # 完成确认：以 statusVersion 裁决注销竞争；CAS 失败返回 false
    def complete(_id, expected_status_version:, next_due:)
      raise NotImplementedError
    end

    def cancel(_id)
      raise NotImplementedError
    end

    def list
      raise NotImplementedError
    end

    def close; end

    # schedule 规范："0 9 * * *"（cron）或 "every:30s"（间隔）
    def self.compute_next(schedule, after_ms)
      if schedule.start_with?("every:")
        after_ms + (Util.parse_duration(schedule.delete_prefix("every:"), "提醒周期") * 1000).to_i
      else
        (Cron.next_after(schedule, Time.at(after_ms / 1000.0)).to_f * 1000).to_i
      end
    end

    def self.normalize_schedule(spec)
      s = spec.to_s.strip
      return s if s.include?(" ") # 5 字段 cron

      "every:#{Util.parse_duration(s, '提醒周期')}s"
    end
  end

  class MemoryCueStore < CueStore
    def initialize
      @mutex = Mutex.new
      @records = {}
    end

    def upsert(record)
      @mutex.synchronize do
        cur = @records[record.id]
        if cur
          # 重复注册（每次 on_stage）：只更新定义，不动 next_due/status（避免无限顺延）
          cur.payload = record.payload
          cur.schedule = record.schedule
        else
          @records[record.id] = record
        end
      end
      nil
    end

    def find(id)
      @mutex.synchronize { @records[id] }
    end

    def due(now, limit)
      @mutex.synchronize do
        @records.values
                .select { |r| r.next_due <= now && (r.status == "active" || (r.status == "running" && r.lease_until <= now)) }
                .sort_by(&:next_due)
                .first(limit)
      end
    end

    def claim(id, owner:, lease_until:)
      now = Util.now_ms
      @mutex.synchronize do
        r = @records[id]
        return nil unless r
        return nil unless r.status == "active" || (r.status == "running" && r.lease_until <= now)

        r.status = "running"
        r.owner = owner
        r.lease_until = lease_until
        r.status_version += 1
        r.status_version
      end
    end

    def complete(id, expected_status_version:, next_due:)
      @mutex.synchronize do
        r = @records[id]
        return false unless r
        return false unless r.status_version == expected_status_version

        r.status = "active"
        r.owner = nil
        r.lease_until = nil
        r.next_due = next_due
        r.status_version += 1
        true
      end
    end

    def cancel(id)
      @mutex.synchronize { @records.delete(id) }
      nil
    end

    def list
      @mutex.synchronize { @records.values.map(&:to_h) }
    end

    def records
      @mutex.synchronize { @records.values.dup }
    end
  end

  # PStore 持久 CueStore：./.troupe/cues.pstore（随 PStoreBackend 落盘）
  class PstoreCueStore < CueStore
    def initialize(path_or_backend)
      @backend = path_or_backend.is_a?(PStoreBackend) ? path_or_backend : PStoreBackend.new(path_or_backend)
      @backend.transaction { |db| db[:cues] ||= {} }
    end

    def upsert(record)
      @backend.transaction do |db|
        cur = db[:cues][record.id]
        if cur
          cur["payload"] = record.payload
          cur["schedule"] = record.schedule
        else
          db[:cues][record.id] = record_to_h(record)
        end
      end
      nil
    end

    def find(id)
      h = @backend.transaction(true) { |db| db[:cues][id] }
      h && from_h(h)
    end

    def due(now, limit)
      @backend.transaction(true) do |db|
        db[:cues].values
                 .select { |h| h["next_due"] <= now && (h["status"] == "active" || (h["status"] == "running" && h["lease_until"] <= now)) }
                 .sort_by { |h| h["next_due"] }
                 .first(limit)
                 .map { |h| from_h(h) }
      end
    end

    def claim(id, owner:, lease_until:)
      now = Util.now_ms
      version = nil
      @backend.transaction do |db|
        h = db[:cues][id]
        if h && (h["status"] == "active" || (h["status"] == "running" && h["lease_until"] <= now))
          h["status"] = "running"
          h["owner"] = owner
          h["lease_until"] = lease_until
          h["status_version"] += 1
          version = h["status_version"]
        end
      end
      version
    end

    def complete(id, expected_status_version:, next_due:)
      ok = false
      @backend.transaction do |db|
        h = db[:cues][id]
        if h && h["status_version"] == expected_status_version
          h["status"] = "active"
          h["owner"] = nil
          h["lease_until"] = nil
          h["next_due"] = next_due
          h["status_version"] += 1
          ok = true
        end
      end
      ok
    end

    def cancel(id)
      @backend.transaction { |db| db[:cues].delete(id) }
      nil
    end

    def list
      @backend.transaction(true) { |db| db[:cues].values.map { |h| from_h(h).to_h } }
    end

    private

    def record_to_h(r)
      { "id" => r.id, "namespace" => r.namespace, "role_id" => r.role_id, "stage_name" => r.stage_name,
        "name" => r.name, "payload" => r.payload, "schedule" => r.schedule, "next_due" => r.next_due,
        "status_version" => r.status_version, "status" => r.status, "owner" => r.owner, "lease_until" => r.lease_until }
    end

    def from_h(h)
      ReminderRecord.new(
        id: h["id"], namespace: h["namespace"], role_id: h["role_id"], stage_name: h["stage_name"],
        name: h["name"], payload: h["payload"], schedule: h["schedule"], next_due: h["next_due"],
        status_version: h["status_version"], status: h["status"], owner: h["owner"], lease_until: h["lease_until"]
      )
    end
  end
end
