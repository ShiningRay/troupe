# frozen_string_literal: true

require "fileutils"
require "pstore"
require_relative "prop_store"

module Troupe
  # PStore 事务化文件后端：stdlib 自带、零 gem 依赖。
  # 定位与 Troupe.js 的 node:sqlite 相同——进程级持久（担保进程崩溃/重启后恢复，
  # 不担保节点丢失与扩缩容再平衡；多节点生产须切换共享存储，DESIGN §7.2）。
  # PStore 事务提供进程内互斥 + 整文件落盘，CAS 在事务内判定即原子。
  class PStoreBackend
    attr_reader :path

    def initialize(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless dir.empty?
      @db = PStore.new(path)
    end

    def transaction(read_only = false)
      @db.transaction(read_only) do
        yield @db
      end
    end
  end

  # 默认文件 PropStore：./.troupe/props.pstore（首次用到才建文件）
  class PStorePropStore < PropStore
    def initialize(path_or_backend, ownership: true)
      @backend = path_or_backend.is_a?(PStoreBackend) ? path_or_backend : PStoreBackend.new(path_or_backend)
      @supports_ownership = ownership
      @backend.transaction do |db|
        db[:props] ||= {}
        db[:ownership] ||= {}
      end
    end

    def ownership_enabled?
      @supports_ownership
    end

    def read(ns, role_id, stage_name)
      k = PropStore.key(ns, role_id, stage_name)
      @backend.transaction(true) do |db|
        rec = db[:props][k]
        rec && StoredProps.new(props: Codec.copy(rec[:props]), revision: rec[:revision],
                               schema_version: rec[:schema_version], fence: rec[:fence])
      end
    end

    def create(ns, role_id, stage_name, props, schema_version:, fencing_token: 0)
      k = PropStore.key(ns, role_id, stage_name)
      stored = nil
      @backend.transaction do |db|
        raise ConflictError, "Props 记录已存在：#{role_id}/#{stage_name}" if db[:props].key?(k)

        rec = { props: Codec.copy(props), revision: 1, schema_version: schema_version, fence: fencing_token }
        db[:props][k] = rec
        stored = StoredProps.new(props: Codec.copy(rec[:props]), revision: 1, schema_version: schema_version, fence: fencing_token)
      end
      stored
    end

    def write(ns, role_id, stage_name, props, expected_revision:, schema_version:, fencing_token: 0)
      k = PropStore.key(ns, role_id, stage_name)
      stored = nil
      @backend.transaction do |db|
        rec = db[:props][k] || raise(ConflictError, "Props 记录不存在：#{role_id}/#{stage_name}")
        unless rec[:revision] == expected_revision
          raise ConflictError, "revision CAS 失败：expected=#{expected_revision} actual=#{rec[:revision]}（#{role_id}/#{stage_name}）"
        end
        if fencing_token < rec[:fence]
          raise ConflictError, "fencing token 过期：token=#{fencing_token} < fence=#{rec[:fence]}，所有权已转移（DESIGN §6.5）"
        end

        rec[:props] = Codec.copy(props)
        rec[:revision] += 1
        rec[:schema_version] = schema_version
        rec[:fence] = fencing_token if fencing_token > rec[:fence]
        stored = StoredProps.new(props: Codec.copy(rec[:props]), revision: rec[:revision],
                                 schema_version: rec[:schema_version], fence: rec[:fence])
      end
      stored
    end

    def delete(ns, role_id, stage_name)
      k = PropStore.key(ns, role_id, stage_name)
      @backend.transaction do |db|
        db[:props].delete(k)
        db[:ownership].delete(k)
      end
      nil
    end

    # ---- 所有权（与 MemoryPropStore 同一合同） ----

    def acquire_ownership(ns, role_id, name, owner:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      rec = nil
      @backend.transaction do |db|
        cur = db[:ownership][k]
        if cur.nil? || cur[:lease_until] <= now || cur[:owner] == owner
          epoch = cur.nil? ? 1 : (cur[:owner] == owner ? cur[:epoch] : cur[:epoch] + 1)
          cur = { owner: owner, epoch: epoch, lease_until: now + lease_ms }
          db[:ownership][k] = cur
          # 接管即前移 fence：旧持有者的后续写入被拒（DESIGN §6.5）
          if (props_rec = db[:props][k]) && epoch > props_rec[:fence]
            props_rec[:fence] = epoch
          end
        end
        rec = cur
      end
      rec && rec[:owner] == owner ? OwnershipRecord.new(owner: rec[:owner], epoch: rec[:epoch], lease_until: rec[:lease_until]) : nil
    end

    def renew_ownership(ns, role_id, name, owner:, expected_epoch:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      ok = false
      @backend.transaction do |db|
        rec = db[:ownership][k]
        if rec && rec[:owner] == owner && rec[:epoch] == expected_epoch
          rec[:lease_until] = now + lease_ms
          ok = true
        end
      end
      ok
    end

    def release_ownership(ns, role_id, name, owner:, expected_epoch:)
      k = PropStore.key(ns, role_id, name)
      @backend.transaction do |db|
        rec = db[:ownership][k]
        # 释放但保留 epoch 墓碑：下次接管 epoch 单调递增（DESIGN §6.5）
        rec[:lease_until] = 0 if rec && rec[:owner] == owner && rec[:epoch] == expected_epoch
      end
      nil
    end
  end
end
