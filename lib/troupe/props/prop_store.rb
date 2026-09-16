# frozen_string_literal: true

require_relative "../codec"
require_relative "../errors"
require_relative "../util"

module Troupe
  # 存储中的一份 Props：并发修订号（revision，CAS 用）与结构版本
  # （schema_version，迁移用）是两个维度（DESIGN §7.2）；fence 为所有权 fencing token。
  class StoredProps
    attr_reader :props, :revision, :schema_version, :fence

    def initialize(props:, revision:, schema_version:, fence: 0)
      @props = props
      @revision = revision
      @schema_version = schema_version
      @fence = fence
    end
  end

  # 所有权记录（DESIGN §6.5）：epoch 为单调递增的 fencing token
  class OwnershipRecord
    attr_reader :owner, :epoch, :lease_until

    def initialize(owner:, epoch:, lease_until:)
      @owner = owner
      @epoch = epoch
      @lease_until = lease_until
    end
  end

  # PropStore（道具间）接口合同（DESIGN §7.2）：
  # * create/write 必须原子（如单条 UPDATE … WHERE revision = ?）；
  # * 冲突抛 ConflictError；
  # * 写结果不确定（网络超时）时，调用方以 read 校验实际 revision 后决定，不盲目重写。
  class PropStore
    def read(_namespace, _role_id, _stage_name)
      raise NotImplementedError
    end

    # 仅当不存在时成功（原子）
    def create(_namespace, _role_id, _stage_name, _props, schema_version:, fencing_token: 0)
      raise NotImplementedError
    end

    # CAS：仅当当前 revision == expected_revision 才写入；返回新 revision，冲突抛 ConflictError
    def write(_namespace, _role_id, _stage_name, _props, expected_revision:, schema_version:, fencing_token: 0)
      raise NotImplementedError
    end

    def delete(_namespace, _role_id, _stage_name)
      raise NotImplementedError
    end

    # 共享存储能力（多节点生产必需）：承载所有权记录与 fencing（DESIGN §6.5）
    def ownership_enabled?
      false
    end

    def acquire_ownership(_ns, _role_id, _name, owner:, lease_ms:)
      raise NotImplementedError, "#{self.class.name} 不支持所有权：多节点生产需部署共享 PropStore（DESIGN §7.2）"
    end

    def renew_ownership(_ns, _role_id, _name, owner:, expected_epoch:, lease_ms:)
      raise NotImplementedError
    end

    def release_ownership(_ns, _role_id, _name, owner:, expected_epoch:)
      raise NotImplementedError
    end

    def close; end

    def self.key(ns, role_id, stage_name)
      "#{ns}\u0000#{role_id}\u0000#{stage_name}"
    end
  end

  # InMemoryPropStore：无持久级别——Rehearsal / 测试（DESIGN §7.2）。
  # 写路径与文件/数据库实现走同一 CAS / fencing 合同，测试不掩盖部署差异。
  class MemoryPropStore < PropStore
    def initialize(ownership: true)
      @mutex = Mutex.new
      @props = {}
      @ownership = {}
      @supports_ownership = ownership
    end

    def ownership_enabled?
      @supports_ownership
    end

    def read(ns, role_id, stage_name)
      @mutex.synchronize do
        rec = @props[PropStore.key(ns, role_id, stage_name)]
        rec && StoredProps.new(props: Codec.copy(rec[:props]), revision: rec[:revision],
                               schema_version: rec[:schema_version], fence: rec[:fence])
      end
    end

    def create(ns, role_id, stage_name, props, schema_version:, fencing_token: 0)
      k = PropStore.key(ns, role_id, stage_name)
      @mutex.synchronize do
        raise ConflictError, "Props 记录已存在：#{role_id}/#{stage_name}" if @props.key?(k)

        rec = { props: Codec.copy(props), revision: 1, schema_version: schema_version, fence: fencing_token }
        @props[k] = rec
        StoredProps.new(props: Codec.copy(rec[:props]), revision: 1, schema_version: schema_version, fence: fencing_token)
      end
    end

    def write(ns, role_id, stage_name, props, expected_revision:, schema_version:, fencing_token: 0)
      k = PropStore.key(ns, role_id, stage_name)
      @mutex.synchronize do
        rec = @props[k] || raise(ConflictError, "Props 记录不存在：#{role_id}/#{stage_name}")
        unless rec[:revision] == expected_revision
          raise ConflictError, "revision CAS 失败：expected=#{expected_revision} actual=#{rec[:revision]}（#{role_id}/#{stage_name}）"
        end
        if fencing_token < rec[:fence]
          raise ConflictError,
                "fencing token 过期：token=#{fencing_token} < fence=#{rec[:fence]}，所有权已转移（DESIGN §6.5）"
        end

        rec[:props] = Codec.copy(props)
        rec[:revision] += 1
        rec[:schema_version] = schema_version
        rec[:fence] = fencing_token if fencing_token > rec[:fence]
        StoredProps.new(props: Codec.copy(rec[:props]), revision: rec[:revision],
                        schema_version: rec[:schema_version], fence: rec[:fence])
      end
    end

    def delete(ns, role_id, stage_name)
      @mutex.synchronize do
        @props.delete(PropStore.key(ns, role_id, stage_name))
        @ownership.delete(PropStore.key(ns, role_id, stage_name))
      end
      nil
    end

    # ---- 所有权（租约 + 单调 epoch，DESIGN §6.5） ----

    def acquire_ownership(ns, role_id, name, owner:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      @mutex.synchronize do
        rec = @ownership[k]
        if rec.nil? || rec[:lease_until] <= now || rec[:owner] == owner
          epoch = rec.nil? ? 1 : (rec[:owner] == owner ? rec[:epoch] : rec[:epoch] + 1)
          rec = { owner: owner, epoch: epoch, lease_until: now + lease_ms }
          @ownership[k] = rec
          # 接管（epoch 前进）即前移 Props 记录的 fence：旧持有者的后续写入被拒（DESIGN §6.5）
          if (props_rec = @props[k]) && epoch > props_rec[:fence]
            props_rec[:fence] = epoch
          end
          OwnershipRecord.new(owner: rec[:owner], epoch: rec[:epoch], lease_until: rec[:lease_until])
        end
      end
    end

    def renew_ownership(ns, role_id, name, owner:, expected_epoch:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      @mutex.synchronize do
        rec = @ownership[k]
        return false unless rec && rec[:owner] == owner && rec[:epoch] == expected_epoch

        rec[:lease_until] = now + lease_ms
        true
      end
    end

    def release_ownership(ns, role_id, name, owner:, expected_epoch:)
      k = PropStore.key(ns, role_id, name)
      @mutex.synchronize do
        rec = @ownership[k]
        if rec && rec[:owner] == owner && rec[:epoch] == expected_epoch
          # 释放但保留 epoch 墓碑：下次接管 epoch 单调递增（fencing 不回退，DESIGN §6.5）
          rec[:lease_until] = 0
        end
      end
      nil
    end

    def ownership_record(ns, role_id, name)
      @mutex.synchronize { @ownership[PropStore.key(ns, role_id, name)] }
    end

    def snapshot
      @mutex.synchronize { { props: @props.dup, ownership: @ownership.dup } }
    end

    def load_raw(hash)
      @mutex.synchronize do
        @props.update(hash.transform_keys(&:to_s)) { |_old, new| new }
      end
    end
  end
end
