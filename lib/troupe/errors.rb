# frozen_string_literal: true

module Troupe
  # 错误分类（DESIGN §6.1）：业务异常 / 请求拒绝 / 执行结果未知 / 存储冲突
  # 每个错误带 kind，跨 Stage 以 {kind:, name:, message:} 传播。
  class TroupeError < StandardError
    def kind
      :internal
    end
  end

  # 存储冲突：CAS 失败 / fencing token 过期（DESIGN §6.5、§7.2）
  class ConflictError < TroupeError
    def kind
      :conflict
    end
  end

  # 执行结果未知：超时、断连——不得假定失败（DESIGN §6.5）。
  # 框架不自动重试；需要安全重试的业务持幂等键。
  class ResultUnknownError < TroupeError
    def kind
      :unknown
    end
  end

  class CallTimeoutError < ResultUnknownError; end
  class ConnectionLostError < ResultUnknownError; end

  # 请求拒绝：校验失败、背压超限、白名单外方法——调用未开始执行、无副作用
  class CallRejectedError < TroupeError
    def kind
      :rejected
    end
  end

  class BoardFullError < CallRejectedError; end
  class BackpressureError < CallRejectedError; end
  class UnknownMethodError < CallRejectedError; end
  class UnknownRoleError < CallRejectedError; end
  class ProtocolError < CallRejectedError; end
  class InvalidActorStateError < CallRejectedError; end
  class SerializationError < CallRejectedError; end

  # 激活失败：Props 加载/迁移/校验/onStage 抛错，或所有权等待超时（DESIGN §5.2）
  class ActivationError < TroupeError
    def kind
      :rejected
    end
  end

  class MigrationError < ActivationError; end
  class OwnershipError < ActivationError; end

  # 业务幂等冲突：同键不同参数（DESIGN §6.5）
  class IdempotencyConflictError < TroupeError
    def kind
      :business
    end
  end

  # 启动期错误（§8.5：约定优于配置，但错误必须响）
  class RoleConflictError < TroupeError; end
  class ConfigError < TroupeError; end

  # 远端业务异常（actor 方法 raise）——保留原始类名与消息
  class RemoteError < TroupeError
    def kind
      :business
    end

    attr_reader :error_name

    def initialize(error_name, message)
      @error_name = error_name
      super(message)
    end
  end
end
