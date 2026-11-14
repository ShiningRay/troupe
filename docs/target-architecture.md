# 目标架构与演进选择

## 定位

Troupe 是多种语言各自 idiomatic 的 virtual actor 框架集合。近期目标是**可验证的单机与小型 silo 集群**，不是立即复制 Orleans 的全部平台或改成独立 mesh。

## 分层

### 1. 共同语义层

- `ActorId = namespace + role/type + key`，字符串 canonical form 明确转义与 Unicode 规则。
- `ActivationId/incarnation` 独立于 ActorId；ownership epoch/fencing token 不等于业务 revision。
- Actor 代理、激活/钝化、strict turn、显式交错、生命周期与 Intermission。
- Call 有 requestId、deadline、trace context、命名错误与 UnknownOutcome；取消和重试不得改变副作用语义。
- Props 有 schemaVersion、revision、显式持久成功；migrate 逐级执行，所有权取得前不得写共享状态。

### 2. 本地运行时层

每种语言选择本地惯用模型：

- TypeScript：Promise + 显式 ActorSlot/CallBoard。
- Elixir：GenServer/OTP + 不可变 Props。
- Ruby：Thread/共享池起步，Fiber 调度经实验决定。
- Crystal：Fiber/Channel + 有界队列；编译器/类型系统辅助生成 manifest，不复制 Ruby 的抢占式 Thread 模型。

本地 runtime 负责背压、异常隔离、排空、时钟注入与 deterministic test。不能用“单线程”“协程”推导分布式单激活。

### 3. 共享正确性层

- 首 Provider 建议 PostgreSQL，Props/ownership/reminders 共用事务与 fencing 约束。
- lease 判断、单调 epoch、写 fencing 和 owner drain 是一组协议，不是独立 SQL helper。
- 本地 Memory/File/SQLite 为开发 Provider；production 模式拒绝无法证明跨节点安全的 Provider。
- 外部副作用需要接收方 epoch 校验或持久 Outbox，不能由状态写 fencing 自动保护。

### 4. 路由、目录与放置层（渐进）

**近期**保留 HashRing + 漂移转发 + ownership，验证扩容/接管。引入目录前先通过 ADR 评估必要性：

- 版本化 membership/directory view。
- register/unregister/cache invalidation、handoff 与 crash recovery。
- capabilities 与 placement policy；默认简单策略可回退。
- 资源放置与 activation rebalancing 放在正确性之后，StatelessWorker 作为显式多实例模型。

不直接复制 Orleans DHT，也不直接采用 Orbit 的独立 mesh；当规模/操作需求证明需要时另做控制面 ADR。

### 5. 消息与调度层

- Show realtime 与 persistent stream 分开命名和 API。
- 可靠流需事件 ID、日志、订阅游标、ack/nack、重放、保留、慢消费者和幂等；优先复用成熟消息 Provider。
- volatile timer 只在 activation 存活时有效；durable reminder 由共享存储发现、认领和重投。
- RPC 超时、取消、重试与 reminder/stream 的重复语义独立定义，禁止自动假定 exactly-once。

### 6. 协议与运维层

- 内部各语言 transport 可保留，公共跨语言协议需 ADR 和 golden fixtures。
- 加入认证、TLS、密钥轮换、RPC allowlist、帧/队列/inflight 预算，敏感异常不直接上线。
- OTel/W3C trace 贯穿跨 Actor/Stage；指标覆盖 activation、ownership、recovery、mailbox、stream lag。
- CI 分层：单元、Provider、跨进程、多节点、故障注入、版本兼容与发布安装。

## 需要 ADR 的关键选择

1. 是否以统一中立协议支持混群，还是只统一语义和 Provider 合同。
2. 目录的必要性、拥有者、视图一致性和故障恢复策略。
3. 持久流复用的 Provider 与最少承诺，不同时自研 broker。
4. 各语言 reentrancy 的可表达子集，禁止以整 Props last-write-wins 隐式冒充相同语义。
5. 何时引入事务/事件溯源，及其与 Outbox 的边界。
