# frozen_string_literal: true

module Troupe
  # 角色注册表（Repertoire，DESIGN §3.2/§8.3）：
  # 显式注册 Troupe.form(actors: [...]) 优先；performs! 宏写进程级默认注册表，
  # form() 不传 actors 时取该注册表快照——同进程多个 Troupe 互不污染。
  class Repertoire
    def self.default
      @default ||= new
    end

    def role_ids
      @roles.keys
    end

    def initialize(roles = {})
      @roles = {}
      roles.each { |klass| register(klass) }
    end

    def register(klass)
      klass.validate_annotations! if klass.respond_to?(:validate_annotations!)
      rid = klass.role_id
      if rid.start_with?("__")
        raise RoleConflictError, "角色名 #{rid.inspect} 非法：双下划线开头保留给系统角色（如 #{Director::ROLE_ID}）"
      end
      if (existing = @roles[rid]) && !existing.equal?(klass)
        raise RoleConflictError,
              "角色名 #{rid.inspect} 冲突：#{existing.name} 与 #{klass.name} 同时声明（DESIGN §8.5）。" \
              "请用 role_id 显式区分，或只注册其中一个"
      end
      @roles[rid] = klass
    end

    def [](role_id)
      klass = @roles[role_id.to_s]
      return klass if klass

      raise UnknownRoleError,
            "未注册角色 #{role_id.inspect}；当前 Repertoire：#{@roles.keys.sort.join(', ')}（DESIGN §8.5）"
    end

    def role?(role_id)
      @roles.key?(role_id.to_s)
    end

    # 每 Troupe 一份注册表快照
    def snapshot
      Repertoire.new(@roles.values)
    end
  end
end
