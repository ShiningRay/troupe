# 当前能力与验证快照（2026-11-14）

## 总体判断

Troupe 有三种实际语言运行时；`troupe-game-demo` 是 Node 应用而非第四种实现。三版都覆盖虚拟激活、生命周期、Props 与路由的若干核心路径，但尚不是一个可互操作的多语言集群，也未达到 Orleans 的完整分布式平台成熟度。

| 实现 | 已有能力 | 生产关键缺口 | 本轮验证 |
|---|---|---|---|
| TypeScript | strict/交错、Props CAS、SQLite/PG、ownership/fencing、TCP 集群、Cue、Show、Booth、OTel、实验热替换 | Show 非持久流；Cue 无 PG；缺强制多机/POSIX/分区验证；安全与发布生态 | 155 passed、4 skipped；typecheck/build 通过。PG 3 与 SIGSTOP 1 未执行 |
| Elixir | GenServer 串行、快照交错、File/DETS Props、distribution、Cue、:pg Show、Director/CLI | 所有权前迁移写；仅 Memory ownership；无共享 Props/Cue/fencing；缺真实多节点验收 | 37/37，单机核心；不代表分布式路径 |
| Ruby | Cell 串行、共享池选项、TCP、Props CAS、租约/fencing、持久 Cue、进程内 Show | 默认测试失败；namespace 测试假阳性；迁移非逐级；无共享存储与真实接管 | 默认入口 logger 失败；诊断运行 89 例 4 failures+3 errors |
| Crystal | 本轮只有设计、路线和可编译脚手架 | Actor 运行时、存储、集群全部待实现 | 只验证 spec/format/build，不宣称框架测试 |

## 跨实现共同缺口

1. **目录与放置**：主要是 HashRing + 本地激活 + 存储所有权，缺少 Orleans 式版本化目录、视图交接、资源放置和再平衡。
2. **可靠消息**：Show 均不是 Orleans persistent streams；Node 只持久化订阅记录。
3. **共享状态与 reminders**：Node 有 PG Props 源码但本轮未验证 PG；Elixir/Ruby 缺生产 Provider；三版都没有完整共享 reminders 证据。
4. **跨语言**：TCP+JSON（各自不同）、Erlang distribution 和不同哈希不能混群；中立协议尚待 ADR。
5. **工程体系**：现有三仓均未发现 CI，真实 Provider、版本矩阵、滚动升级和故障注入需要制度化。
6. **高级模块**：事务、事件溯源、extensions 和丰富 Provider 生态不是当前核心，不能由幂等/CAS 替代。

## 证据原则

- 单元测试通过只证明被执行的路径。
- SQLite 同机多进程不等于不同主机共享状态。
- 可选测试 skip 必须在报告中列出，不能省略。
- 文档中的历史性能数据不自动代表当前实现或默认配置。
- 功能名相同不保证语义相同，尤其 reentrancy、at-least-once、ownership、persistent subscription。
