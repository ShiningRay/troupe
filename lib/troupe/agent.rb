# frozen_string_literal: true

module Troupe
  # Agent（经纪人，DESIGN §3.2）：位置透明的代理引用。
  # method_missing 动态派发——无代码生成；类型面只有 RPC 方法，
  # 白名单外的成员（props / on_stage / save_props …）在派发端即被拒绝。
  class Agent
    def initialize(troupe, role_class, stage_name, timeout = nil)
      @troupe = troupe
      @role_class = role_class
      @stage_name = stage_name
      @timeout = timeout
    end

    # 覆盖本 Agent 上的 Call 响应期限（默认 30s，DESIGN §5.4）
    def with_timeout(spec)
      Agent.new(@troupe, @role_class, @stage_name, spec)
    end

    def role_id
      @role_class.role_id
    end

    def stage_name
      @stage_name
    end

    def method_missing(name, *args, **kwargs, &blk)
      unless @role_class.valid_rpc?(name)
        raise UnknownMethodError,
              "Agent 无法调用 #{name}：不在角色 #{role_id} 的 RPC 白名单（生命周期钩子、基类成员、" \
              "未定义方法均不可经 RPC 调用，DESIGN §3.2/§6.1）"
      end
      if blk || !kwargs.empty?
        raise SerializationError,
              "Agent 调用 #{name} 不支持 block 与关键字参数：JSON 边界只传位置参数数组（DESIGN §6.1）"
      end

      @troupe.dispatch_call(@role_class, @stage_name, name, args, @timeout)
    end

    def respond_to_missing?(name, include_private = false)
      @role_class.valid_rpc?(name) || super
    end

    def inspect
      "#<Troupe::Agent role=#{role_id} stage_name=#{@stage_name}>"
    end
  end
end
