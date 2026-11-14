# Orleans 对标基线

## 版本和架构

- 本地参考：`reference-repos/orleans`，commit `8320d257ee99b93078dfe0de828640ebca0ab25b`。
- 源码版本声明：`10.0.0`（`Directory.Build.props:64-67`），不将该声明等同为已验证的发布包。
- Orleans grain 在 silo 内执行；Troupe 保持应用内 Stage，不默认引入独立 mesh。
- Orbit 仅作为架构对照：其 2.0 alpha 快照是 thin client + mesh，且没有默认持久化、streams、reentrancy 等完整能力，不能与 Orleans 混合计算功能数。

## 能力基线

| 领域 | Orleans 参考行为 | Troupe 需要学习的契约 |
|---|---|---|
| Identity | GrainType+key，逻辑 GrainId 与 ActivationId 分离 | 稳定业务身份和每次激活 incarnation 不可混淆 |
| Lifecycle | activation setup、idle collection、可观察停机与 deactivation reason | 激活 single-flight、明确失败/排空/失效及回调边界 |
| Scheduling | turn-based 串行；reentrant、read-only、MayInterleave、call-chain 控制 | 默认安全串行，交错必须声明一致性，不用线程/协程名词代替语义 |
| Messaging | request/response、超时、可传播取消、one-way、失败通知 | 超时不等于失败；取消与响应期限分开；未知结果需幂等 |
| Directory | DHT 分区、视图版本、handoff/recovery、locator cache | 目录一致性、缓存失效、崩溃恢复不是可省略功能 |
| Placement | compatible silos、random/prefer-local/resource-aware、rebalancing | 从哈希放置渐进到能力/资源策略，保留可解释回退 |
| Membership | 表维护、IAmAlive、直接/间接探测、suspect/dead | 健康证据与路由视图、lease/fencing 的协作及分区恢复 |
| Persistence | IGrainStorage、ETag、显式写、Provider 扩展 | CAS/schema migration/fencing 一致性；本地文件不是共享状态 |
| Timers/reminders | activation timer 与持久 reminder 分离 | 内存 Cue 与共享持久 reminder 分别承诺和验收 |
| Streams | 持久队列适配、sequence token、pull agent、订阅握手/平衡 | Show 若要可靠，必须有事件日志、游标、确认、重放和背压 |
| Extensions/transactions | activation extensions、分布式参与方与恢复 | 高级独立模块；单机 CAS/幂等不能冒充 ACID 跨 Actor 事务 |
| Serialization | 代码生成、版本容错 serializer/copier/invoker | 语言中立 schema 与稳定 ID；不复制 .NET 私有协议 |
| Observability | metrics、ActivitySource、W3C trace context | 跨 Actor/Stage trace、错误/结果未知、目录/恢复/流指标 |
| Testing | 核心、目录、放置、Provider、流、事务和分布式测试分层 | CI 真实 Provider/多进程/故障注入，不把跳过当通过 |

## 参考源码位置

- 目录：`src/Orleans.Runtime/GrainDirectory/DistributedGrainDirectory.cs`。
- 放置：`src/Orleans.Runtime/Placement/ResourceOptimizedPlacementDirector.cs`。
- 调度：`src/Orleans.Runtime/Scheduler/WorkItemGroup.cs`。
- 取消：`src/Orleans.Runtime/Cancellation/GrainCallCancellationManager.cs`。
- 流：`src/Orleans.Streaming/PersistentStreams/`。
- 事务：`src/Orleans.Transactions/`。
- 序列化：`src/Orleans.Serialization/`、`src/Orleans.CodeGenerator/`。

这些是实现参照，不要求 Troupe 复制其全部复杂度。每个阶段必须写出要保留的行为、反例和可验证门槛。
