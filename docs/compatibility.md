# 共同契约与互操作边界

## 当前状态

**尚未支持跨语言混群。** Node/Ruby 的 TCP+JSON 结构、哈希、错误和生命周期不同，Elixir 使用 Erlang distribution/term。三版 API 相似不代表协议兼容。

## 不可协商的核心语义

| 契约 | 最小要求 | 必须有的反例测试 |
|---|---|---|
| Identity | 稳定 namespace/role/key，编码和哈希明确 | Unicode、分隔符、空 key、跨实现同 key 同身份 |
| Activation | 单飞、逻辑 identity 与 incarnation 分离 | 并发首调、崩溃重激活、旧实例调用 |
| Ownership | 先 acquire，再任何共享写；epoch 单调 | 冻结恢复旧写、迁移竞争、释放后接管 |
| Props | revision CAS、schemaVersion 逐级迁移、持久成功后回复 | CAS 冲突、v1→v3、失败不得半提交 |
| Turn | 默认严格串行；交错显式声明 | A/B/A 调度、写饥饿、保存中失效、长任务超时 |
| Call | requestId/deadline/错误类型；UnknownOutcome 不是失败 | 排队超时、执行超时、断连、重复幂等请求 |
| Cancellation | 协作传播，不强制假装终止不可取消代码 | 本地/远程取消、目标已结束、取消与超时竞争 |
| Cue | timer 与 durable reminder 分离；至少一次需幂等 | 宕机重投、取消竞争、慢 tick 合并、归属漂移 |
| Stream | 实时通知与持久流分开 | 订阅离线、coordinator 宕机、重放、重复与慢消费 |
| Compatibility | 方法/参数/schema/wire/idempotency 规则可检查 | 新旧节点混跑、状态升级后回滚、未知字段/错误 |

## 互操作 ADR 需要冻结的内容

1. **Identity**：canonical string/bytes、role/type ID、key 类型和哈希算法；不能直接采用某一语言 runtime hash。
2. **方法/schema**：稳定的 interface/method ID、字段 ID、可选/必填、未知字段处理和版本协商；可使用 Protobuf/其他 IDL，须评估各语言生成器。
3. **Envelope**：requestId、activation hint、deadline、hop/view version、traceparent、flags、cancellation。
4. **Payload**：语言中立类型、时间/十进制/字节/大整数、禁止函数/进程引用；明确复制与深度限制。
5. **Errors**：命名 code、retryable、结果未知、business 与 framework 错误分离，敏感 stack 不上线。
6. **Placement/ownership**：目录视图、lease、epoch、provider 约束与转发规则，不仅共享 JSON 形状。
7. **兼容策略**：协议版本、feature negotiation、golden fixtures、滚动混跑与回滚。

## 决策路径

- 若只要求**统一语义**：为每语言写共享 contract tests，无强制公共 transport，保留独立集群。
- 若要求**跨语言客户端**：先提供中立 gateway/protocol，再允许异构 SDK 访问同一 silo 集群。
- 若要求**异构 silo 混群**：还需统一 membership、directory、placement、roles/capabilities、故障恢复与滚动升级，工作量显著大于 JSON 统一。

默认推进顺序：共享契约测试 → 中立协议实验 → 跨语言客户端 → 是否异构 silo 的独立评审。不得跳过最后评审宣称多语言集群。
