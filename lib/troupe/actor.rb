# frozen_string_literal: true

require "set"

require_relative "util"

module Troupe
  # Actor 基类：演员 = 代码 + 框架托管的 Props（DESIGN §3.1、§7.1）。
  #
  #   class CartActor < Troupe::Actor
  #     role_id "cart"          # 可选；默认 = 类名去 "Actor" 后缀
  #     intermission "10m"      # 空闲超时自动下场；默认 5m
  #     initial_props { { "items" => [] } }   # 首次登台的初始状态（默认 {}）
  #     schema_version 1
  #     performs!               # 可选：注册到进程级默认表（等价 @Performs）
  #     improv :refresh         # 可选：标注可交错方法（@Improv）
  #     read_only :peek         # 可选：标注只读方法（@ReadOnly）
  #
  #     def on_stage = ...      # 生命周期钩子（不在 RPC 白名单）
  #     def add(item) = ...
  #   end
  #
  # Props 约定：JSON 边界语义——Hash 键一律字符串、Symbol → String、
  # Time/Date → ISO 8601（本地/远程/Rehearsal 行为一致，DESIGN §6.1）。
  class Actor
    # 生命周期钩子与基类成员不可经普通 RPC 调用（信任边界，DESIGN §6.1）
    LIFECYCLE_METHODS = %i[on_stage off_stage on_cue migrate_props validate_props!].freeze
    DEFAULT_CALL_BOARD_LIMIT = 1024

    class << self
      # 稳定角色名：类重命名会让旧状态无法寻址，持久业务应显式声明（DESIGN §3.2）
      def role_id(value = nil)
        @role_id = value.to_s unless value.nil?
        @role_id || derive_role_id
      end

      def derive_role_id
        base = name.to_s.split("::").last.to_s
        base.end_with?("Actor") ? base[0...-"Actor".length] : base
      end

      # 空闲超时（Intermission）；存原始 spec，由 Cell 结合 Troupe 默认值解析
      def intermission(spec = nil)
        @intermission_spec = spec unless spec.nil?
        @intermission_spec
      end

      # 首次登台的初始状态工厂；需要结构的 Props 必须提供（默认 {}）
      def initial_props(&blk)
        @initial_props_block = blk if blk
        @initial_props_block
      end

      def build_initial_props
        blk = initial_props
        blk ? blk.call : {}
      end

      # 结构版本（schemaVersion，DESIGN §7.4）：状态形状演进时 +1，配 migrate_props
      def schema_version(value = nil)
        @schema_version = Integer(value) unless value.nil?
        @schema_version || 1
      end

      # @Performs 等价物：注册到进程级默认注册表（便利语法，不是唯一入口）
      def performs!
        Repertoire.default.register(self)
        nil
      end

      # 交错执行标注（DESIGN §5.4）：@Improv 等价
      def improv(*methods)
        annotate(:improv, methods)
      end

      # @ReadOnly 等价：不改 Props 的只读方法，可与其它标注方法交错
      def read_only(*methods)
        annotate(:read_only, methods)
      end

      # :strict（独占）或 :annotated（可交错；标注种类 improv/read_only 都算 annotated）
      def call_kind(method)
        (@annotations || {}).key?(method.to_sym) ? :annotated : :strict
      end

      def call_board_limit(value = nil)
        @call_board_limit = Integer(value) unless value.nil?
        @call_board_limit || DEFAULT_CALL_BOARD_LIMIT
      end

    # RPC 白名单 = 本类自定义的 public 实例方法 − 生命周期钩子。
    # 接收端始终校验：这是安全边界，不依赖调用方类型面（DESIGN §6.1）。
    def rpc_methods
      validate_annotations!
      @rpc_methods ||= begin
        methods = (public_instance_methods(false) - LIFECYCLE_METHODS).sort.freeze
        @rpc_set = methods.to_set.freeze
        methods
      end
    end

    # 热路径 O(1) 白名单校验（Agent 派发与接收端 validate 每次调用都查）
    def valid_rpc?(method)
      rpc_methods
      @rpc_set.include?(method.to_sym)
    end

    # arity 记忆化：validate_call! 每次调用都要查，instance_method 反射不便宜。
    # 注解校验保证"先定义再标注/注册"，注册后方法集不变，缓存安全。
    def rpc_arity(method)
      cache = (@rpc_arities ||= {})
      return cache[method] if cache.key?(method)

      cache[method] = instance_method(method).arity
    end

      # 标注校验延迟到注册/首次使用（DSL 顺序自由），form() 时尽早报错（§1.3 错误必须响）
      def validate_annotations!
        return if @annotations_validated

        (@annotations || {}).each_key do |m|
          unless method_defined?(m) || private_method_defined?(m)
            raise ConfigError, "#{name}.#{m} 不存在，无法按 #{@annotations[m]} 执行（先定义方法再标注）"
          end
        end
        @annotations_validated = true
      end

      def valid_rpc?(method)
        rpc_methods.include?(method.to_sym)
      end

      private

      def annotate(kind, methods)
        methods.each do |m|
          (@annotations ||= {})[m.to_sym] = kind
        end
        @annotations_validated = false
        nil
      end
    end

    attr_reader :props

    # 只能由框架在激活时构造；用户不直接 new Actor
    def initialize(context)
      @context = context
      @props = context.props
    end

    def stage_name
      @context.stage_name
    end

    def role_id
      self.class.role_id
    end

    # 所有权 fencing token（生产集群共享存储下非 0；外部副作用接收方应校验，DESIGN §6.5）
    def fencing_token
      @context.fencing_token
    end

    # 显式写（DESIGN §7.1）：持久成功语义——CAS 提交成功后才返回
    def save_props
      @context.save_props
    end

    # 内存 Cue：随实例下场消失，仅在场期间有效（DESIGN §3.3）
    def register_cue(name, every, &blk)
      @context.register_cue(name, every, blk)
    end

    def cancel_cue(name)
      @context.cancel_cue(name)
    end

    # 持久提醒：写入 CueStore，下场后仍触发，触发即重新登台（DESIGN §3.3、§7.5）
    def schedule_reminder(name, spec, payload: nil)
      @context.schedule_reminder(name, spec, payload)
    end

    def cancel_reminder(name)
      @context.cancel_reminder(name)
    end

    # Actor 互调（DESIGN §10.1）：经当前 Troupe 的 Repertoire 校验
    protected def cast(klass_or_role_id, stage_name, timeout: nil)
      @context.troupe.cast(klass_or_role_id, stage_name, timeout: timeout)
    end

    # ---- 生命周期钩子（子类按需覆盖） ----

    def on_stage; end

    def off_stage; end

    # 持久提醒的稳定入口（DESIGN §3.3）
    def on_cue(name, payload)
      Log.warn("#{self.class.name} 收到未处理的提醒 #{name.inspect}")
    end

    # 结构迁移（DESIGN §7.4）：stored.schema_version < 类版本时逐级调用
    def migrate_props(stored, from_version)
      raise MigrationError,
            "#{self.class.name}（#{role_id}）Props schema_version=#{from_version} < 目标 #{self.class.schema_version}，" \
            "但未提供 migrate_props：请在 Actor 中定义 migrate_props(stored, from_version) 返回迁移后的 Props"
    end

    # 运行时验证入口（DESIGN §7.4）：JSON 可解析 ≠ 满足业务结构
    def validate_props!(props); end

    def inspect
      "#<#{self.class.name} role=#{role_id} stage_name=#{stage_name}>"
    end
  end
end
