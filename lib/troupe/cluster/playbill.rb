# frozen_string_literal: true

module Troupe
  # Playbill（节目单，DESIGN §6.3）：纯一致性哈希、无目录。
  # `xxh32(namespace + ":" + roleId + ":" + stageName)` → HashRing → 归属 Stage。
  # 环视图跟随 Roster 版本惰性重建。
  class Playbill
    def initialize(troupe, roster)
      @troupe = troupe
      @roster = roster
      @lock = Mutex.new
      @ring = nil
      @ring_version = -1
    end

    # 返回归属 Stage 的 advertise 地址；无成员视图（未启用集群）返回 nil
    def owner_address(namespace, role_id, stage_name)
      view = @roster.view
      @lock.synchronize do
        if @ring.nil? || view[:version] != @ring_version
          ring = HashRing.new
          view[:addresses].each { |a| ring.add_node(a) }
          @ring = ring
          @ring_version = view[:version]
        end
      end
      @ring.get_node("#{namespace}:#{role_id}:#{stage_name}")
    end

    # CLI `ring`：虚拟节点分布与均衡度
    def distribution
      owner_address(@troupe.config.namespace, "__ring__", "__view__") # 触发重建
      dist = @ring.distribution
      total = dist.values.sum
      {
        "nodes" => dist.keys.sort,
        "vnodes" => total,
        "perNode" => dist.transform_keys(&:to_s).sort.to_h,
        "minShare" => (dist.values.min.to_f / total).round(4),
        "maxShare" => (dist.values.max.to_f / total).round(4)
      }
    end
  end
end
