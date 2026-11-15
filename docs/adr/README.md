# 架构决策记录

ADR 用于冻结跨语言会互相影响的决定。每份 ADR 应包含背景、选项、决定、影响、验证和回退，不以后续代码默默改变语义。

## 已接受

| 编号 | 主题 | 实证 |
|---|---|---|
| [ADR-0007](0007-external-endpoint-layering.md) | 外部端点分层：core / transport / gateway / web 框架边界；新增伴生 shard troupe-gateway | [troupe-chat](https://github.com/ShiningRay/troupe-chat) 首个网关实现 |

## 待决

| 编号 | 主题 | 前置条件 |
|---|---|---|
| ADR-001 | 统一语义、跨语言客户端或异构 silo 的目标范围 | 先完成 [共同契约](../compatibility.md) 评审 |
| ADR-002 | HashRing+ownership 与版本化 directory 的演进 | M1 真实故障基线 |
| ADR-003 | 公共身份/schema/envelope/错误/协议版本与 IDL | ADR-001 范围明确 |
| ADR-004 | Persistent stream Provider、ack/replay/保留与幂等 | 明确 Show 的实时与可靠分轨 |
| ADR-005 | 各语言 reentrancy 的可表达子集 | 对现有 Ruby/Elixir 语义差异完成反例测试 |
| ADR-006 | 外部副作用 Outbox、事件溯源和事务边界 | 共享状态与可靠消息已有实证 |

## 初始已接受方向（非 ADR 编号决定）

- 以 Orleans 10.0 为主要语义参照，不机械复制全部 API。
- 保持应用内 Stage，近期不引入独立 mesh 控制面。
- 正确性/共享容错先于可靠流、目录和事务。
- 当前不支持跨语言混群；任何互操作声明必须限定范围并有协议测试。
- Crystal 从 Fiber/Channel 模型和本地核心起步，不复制 Ruby 的 Thread-per-Actor。
