# 分阶段路线图与验收门禁

## 原则

阶段按依赖排序，而不是给每个 Orleans 模块平均分配工作。各语言可有不同进度，但宣称同一能力必须通过相同语义验收。

## M0：可信基线与正确性修复

- Node：修正 Show 文档/丢失语义、PG optional dependency、热替换检查范围；建立 typecheck/build/test CI。
- Elixir：修所有权前迁移写、Roster 角色协商声明；保持单机 37 项并新增真实双节点测试。
- Ruby：修 logger、Rehearsal namespace、nil 断言与逐级迁移；建立 Ruby 版本矩阵。
- Crystal：设计/计划/脚手架、spec/format/build CI；不提前写分布式承诺。
- 全部：Issues、文档和验证快照可追溯。

**退出门禁**：干净 checkout 的标准测试入口可复现；任何已知失败/跳过都明示；迁移与接管测试确实读取旧 Props；未持有 epoch 不得写共享状态。

## M1：共享生产容错

- PostgreSQL Provider 合同统一：Props CAS、ownership、reminders、fencing。
- 真实多进程/节点测试：扩容、硬杀、冻结恢复、租约接管、旧写拒绝、优雅排空、存储暂断。
- 生产 Provider 准入与角色/协议协商；安全传输和密钥管理方案。
- 统一跨实现错误、超时、幂等、迁移与生命周期 contract tests。

**退出门禁**：同一 Actor 不出现未防护的双活成功写；旧 epoch 写被拒；Props/reminders 在节点故障后可恢复；测试拓扑与 Provider 可复现。

## M2：调度与可靠消息

- 完整 timeout/cancellation/UnknownOutcome/背压契约，含远程取消和不可取消用户任务边界。
- 统一 volatile timers 与 durable reminders；慢 tick、取消竞争、归属迁移和重投均有验证。
- Show 保持实时通知；持久流单独选择 Provider 与协议，完成事件日志、游标、ack/replay 和慢消费者。
- 外部副作用采用接收方 fencing 或持久 Outbox，明确重复和乱序。

**退出门禁**：发布者、协调者、订阅者各自宕机后恢复语义符合文档；不承诺 exactly-once；没有“重试三次后丢弃”却称持久流的实现。

## M3：目录、放置与弹性

- ADR 决定 HashRing+ownership 是否演进为版本化目录；实现注册、缓存失效、视图交接和崩溃恢复。
- capabilities、可插拔 placement、热点/资源指标、rebalancing 与回退策略。
- 统一基准覆盖冷激活、驻留、单热点、分散负载、网络、持久写、目录恢复。

**退出门禁**：目录变更和节点崩溃不会造成静默多 owner；放置可解释、可观测；恢复期间失败有明确分类与上限。

## M4：版本化编程模型与互操作

- 先统一契约/golden fixtures，再 ADR 选择公共 IDL/协议与客户端或异构 silo 范围。
- 建立语言中立身份、方法/schema、payload、错误、deadline/cancel、trace 和兼容矩阵。
- 不复制 .NET/JVM/Ruby/BEAM 私有序列化；协议协商、未知字段、滚动升级/回滚可验证。

**退出门禁**：按 ADR 声明的互操作范围实测通过；若只支持客户端或统一语义，不宣称异构 silo 混群。

## M5：高级模块与生态

- Provider 扩展与兼容测试套件、Booth/OTel、发布安装/签名/回滚。
- 持久 Outbox 与快照恢复之后，评估事件溯源、grain extensions 和分布式事务。
- 事务必须独立定义隔离级别、参与方恢复与存储协议，不从单机 CAS 推导。

## 各阶段不应做什么

- 不用测试数量、功能名或 README 里程碑替代实际验收。
- 不让四语言同时分叉实现不同的公共协议、目录或流语义。
- 不在没有共享 Provider 与故障证据时宣称 production-ready。
- 不为了功能对齐引入所有语言都不必要的复杂度。
