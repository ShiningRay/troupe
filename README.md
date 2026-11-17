# Troupe

Troupe 多语言实现的统一架构与路线图。主要对标 **Orleans 10.0** 的 silo runtime 语义，不以复制全部模块或 API 为目标。

**网站**：<https://shiningray.github.io/troupe/>

## 语言实现

| 实现 | 语言 | 当前状态 | 入口 |
|---|---|---|---|
| [Troupe.js](https://github.com/ShiningRay/troupe-js) | TypeScript / Node.js | **主线**：M1–M11 与 P0–P3 全部交付（fencing 全路径、目录化路由、PG Cue/Stream/Outbox、混沌入 CI、golden fixtures、Node 22/24 × Linux/Windows × PG16 发布矩阵） | [ROADMAP](https://github.com/ShiningRay/troupe-js/blob/main/docs/ROADMAP.md) / [VERIFICATION](https://github.com/ShiningRay/troupe-js/blob/main/docs/VERIFICATION.md) |
| [Troupe.go](https://github.com/ShiningRay/troupe-go) | Go | M0–M6 全交付：单机核心→PG 跨节点接管→TCP 集群→持久流→版本化目录/放置/再平衡→OTel/事件溯源/滚动升级，全仓 `-race` 绿 | [DESIGN](https://github.com/ShiningRay/troupe-go/blob/main/DESIGN.md) / [COMPATIBILITY](https://github.com/ShiningRay/troupe-go/blob/main/docs/COMPATIBILITY.md) |
| [Troupe.cr](https://github.com/ShiningRay/troupe-cr) | Crystal | M0–M6 交付：PG Provider（`cross_node_safe`）+ TCP transport + 持久流 + 版本化 directory + OTel OTLP 零依赖导出，golden 对齐 | [DESIGN](https://github.com/ShiningRay/troupe-cr/blob/main/DESIGN.md) / [PLAN](https://github.com/ShiningRay/troupe-cr/blob/main/PLAN.md) |
| [Troupe.rb](https://github.com/ShiningRay/troupe-rb) | Ruby | 运行时核心 M1–M4（租约/fencing、持久 Cue、持久流、Outbox/Inbox）+ M5 架构裁决文档；零 gem 依赖；多机接管未验证（[VERIFICATION](https://github.com/ShiningRay/troupe-rb/blob/main/docs/VERIFICATION.md) 明示） | [ROADMAP](https://github.com/ShiningRay/troupe-rb/blob/main/docs/ROADMAP.md) |
| [Troupe.ex](https://github.com/ShiningRay/troupe-elixir) | Elixir | BEAM 移植单机核心（37 测试）：零第三方依赖、File/DETS Props、`:pg` Show、Director/CLI；生产容错待补 | [ROADMAP](https://github.com/ShiningRay/troupe-elixir/blob/main/docs/ROADMAP.md) |

## 生态与配套

| 仓库 | 定位 |
|---|---|
| [troupe-gateway](https://github.com/ShiningRay/troupe-gateway) | Crystal 伴生：外部端点传输桥（ADR-0007 L3） |
| [coin-rush-client](https://github.com/ShiningRay/coin-rush-client) | Coin Rush 浏览器客户端（零构建 Canvas，可连任意协议实现） |
| [coin-rush-servers](https://github.com/ShiningRay/coin-rush-servers) | Coin Rush 服务器端五语言实现：TS/Crystal/Ruby/Elixir/Go（[协议](https://github.com/ShiningRay/coin-rush-servers/blob/main/PROTOCOL.md)） |
| [troupe-bench-suite](https://github.com/ShiningRay/troupe-bench-suite) | 跨实现统一基准（场景与结果需版本化复核） |

## 文档

- [Orleans 对标基线](docs/orleans-baseline.md)
- [当前能力与验证快照](docs/current-state.md)
- [目标架构与演进选择](docs/target-architecture.md)
- [共同契约与互操作边界](docs/compatibility.md)
- [分阶段路线图与验收门禁](docs/roadmap.md)
- [Issues 与文档提交索引](docs/issues.md)
- [ADR 索引](docs/adr/README.md)

## 统一原则

1. **先正确，后功能**：所有权、fencing、迁移和恢复没有反例验证时，不添加更多分布式模块。
2. **运行时优势不替代分布式契约**：BEAM 进程、Crystal Fiber、Ruby Thread、Node Promise 都不自动等于单激活或容错。
3. **同一语义，本地 idiomatic API**：不要求四种语言具有相同语法，要求关键行为与错误可验证一致。
4. **不虚构互操作**：不同 JSON/TCP/Erlang term 不是公共协议；ADR 通过前各自独立部署。
5. **不承诺 exactly-once**：超时时结果未知，重试依赖幂等；流与副作用分别定义持久化、确认和恢复。
6. **生产证据必须可复现**：CI、真实 Provider、进程/节点拓扑、故障注入和版本矩阵共同构成验收。

## 当前非目标

- 不是把 Orleans 的 .NET 序列化、DI 或事务 API 机械移植到每种语言。
- 不是立即引入独立 mesh 控制面或大规模控制平面。
- 不是在所有语言同时实现全部 Orleans 模块。
- 不是用更多 pub/sub、重试或 pub/sub 名称掩盖缺少持久日志的事实。

本仓负责协调，不替代各语言仓的实现、测试和 Issue 跟踪。
