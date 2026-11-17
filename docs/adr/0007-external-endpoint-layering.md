# ADR-0007：外部端点分层——core / transport / gateway / web 框架边界

状态：**Accepted**（2026-11-15）
实证来源：[troupe-chat](https://github.com/ShiningRay/troupe-chat)（troupe.cr + tessell 聊天室）首个外部消费者网关的完整实现与验证。
关联：troupe.cr issue [#2](https://github.com/ShiningRay/troupe-cr/issues/2)（OutboxDispatcher 批量/后台派发）。

## 背景

troupe-chat 需要把浏览器/桌面等**外部客户端**接入 troupe.cr actor。首个实现手写了完整 WebSocket 网关（约 280 行），其中约一半是与 chat 业务无关的通用传输管理：

- 会话注册表与生命周期（连接/断线清理）；
- 每连接出站有界 mailbox + 限时投递 + 慢消费者剔除；
- Outbox 派发循环（轮询 → 交付 → 标记，至少一次）；
- 至少一次事件的 `event_id` 去重缓冲。

这些在任何"外部客户端 ↔ actor"的端点上都要重写一遍。由此产生边界问题：troupe.cr 是否应该内置 HTTP/WS 框架？

## 选项

| 选项 | 内容 | 结论 |
|---|---|---|
| A | core 内置 HTTP/WS 框架 | 拒绝：core 零网络依赖是资产；路由/中间件/序列化是 web 框架的维护面；Orleans（端点交给 ASP.NET Core 共宿主）、Akka（Akka HTTP 独立模块）均不这么做 |
| B | 不做，各应用手写 | 现状；三块通用轮子（mailbox/派发循环/去重）每个消费者重复一遍，且实现质量参差 |
| C | **官方伴生 shard（troupe-gateway）：传输桥** | **采纳**：只收编通用传输管理，协议路由留给应用；依赖单向 gateway → troupe → stdlib |
| D | 做全功能 web 框架（路由/控制器/模板） | 拒绝：属 kemal/athena/lucky 领域，troupe 不卷入 |

## 决定

外部端点分四层，职责与依赖方向如下（上层依赖下层，禁止反向）：

| 层 | 归属 | 职责 | 明确不负责 |
|---|---|---|---|
| L1 core | troupe.cr | Stage/Agent/Actor/Outbox/Show/PropStore；零 HTTP/WS 依赖 | 任何网络 I/O |
| L2 transport | troupe.cr（可选模块，如 M3 TCP transport） | **actor ↔ actor** RPC（白名单/背压/超时语义） | 外部（非 actor）客户端接入 |
| L3 gateway | **伴生 shard `troupe-gateway`** | 外部客户端 ↔ actor 的传输桥：WS 会话生命周期、出站有界 mailbox 与溢出策略（drop/disconnect）、Outbox 派发循环、事件去重缓冲、握手信息（path/headers）与会话元数据暴露 | 应用协议路由、业务语义（房间/昵称等）、认证授权策略、路由/中间件/序列化 |
| L4 web 框架 | kemal / athena / lucky 等 | 路由、控制器、模板、复杂认证 | —— |

概念映射（设计参照 [Phoenix Channels](https://hexdocs.pm/phoenix/channels.html) 的概念模型，而非造 web 框架）：

| Phoenix Channels | Troupe |
|---|---|
| PubSub | ShowHub（在线尽力） |
| 可靠通道 | Outbox（与 Props 同原子提交，至少一次 + 消费方去重） |
| topic | ActorId |
| transport | gateway 会话 |
| presence | 应用 Props（如房间成员表） |

拓扑留为应用决策：会话放网关内存（troupe-chat 现方案，ordered broadcast 走 Outbox 更直接）或每连接一个 session actor（per-client 背压语义，Orleans 惯例），gateway 不预设。

## 影响

1. troupe.cr core 不新增任何 HTTP/WS 依赖；L2 transport 保持独立可选模块。
2. 新增伴生 shard `troupe-gateway`（Crystal；依赖 `troupe` + stdlib），对外 API 收敛为：会话对象（id/meta/send/close）、`on_message` / `on_connect` / `on_disconnect` 回调、`on_outbox` 事件回调 + `track/untrack` actor 注册、溢出策略与 mailbox 参数可配。
3. 应用只需提供协议路由（上行解析 → typed Agent 调用；事件 → 下行载荷），presence 自回声抑制等业务语义留在应用。
4. 客户端侧（连 WS 的纤程封装）不在 gateway 职责内——stdlib `HTTP::WebSocket` 足够。
5. troupe.cr issue #2 的产出（`poll_all` / 后台派发）由 gateway 直接消费，两者落地互为验证。

## 验证

- `troupe-gateway` 自带 spec：路由回调、会话元数据、Outbox 派发与去重、溢出策略（drop）、断线清理。
- 外部消费者回归：troupe-chat 服务端改用 gateway 后，原 14 例 spec 与双客户端 E2E（互见/历史/presence/慢消费者）不退化。
- **多语言化（2026-11-18）**：L3 契约已按同一移植矩阵在五语言落地——
  [troupe-gateway-js](https://github.com/ShiningRay/troupe-gateway-js)（claim 型 OutboxSource + troupe-js PostgresOutboxStore 适配）、
  [troupe-gateway-rb](https://github.com/ShiningRay/troupe-gateway-rb)（接 trouperb OutboxDispatcher）、
  [troupe-gateway-go](https://github.com/ShiningRay/troupe-gateway-go)（逐 actor 轮询 troupe.OutboxStore）、
  [troupe-gateway-elixir](https://github.com/ShiningRay/troupe-gateway-elixir)（内置 `OutboxSource` behaviour + ETS 源——troupe-elixir 核心暂无 Outbox，按裁决由伴生包内置，生产可换 claim/lease 型 PG 实现）。
  各仓移植 Crystal spec 的 8 项行为矩阵并各自 CI 全绿；语义差异（并发模型/Outbox API/track 语义）见各仓 README「与 Crystal 版的差异」。

## 回退

gateway 是纯伴生 shard，无 core 语义耦合：停止维护时应用回退为手写网关（迁移面 = 替换回调装配，协议与 actor 层不动）。若未来 Crystal stdlib 或社区库提供了等价能力，shard 可废弃而不影响 troupe.cr 版本节奏。
