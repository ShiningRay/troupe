# Issues 与方案提交索引

## TypeScript — ShiningRay/troupe-js

方案：[Orleans 差距](https://github.com/ShiningRay/troupe-js/blob/main/docs/ORLEANS_GAP.md) · [路线](https://github.com/ShiningRay/troupe-js/blob/main/docs/ROADMAP.md) · [验证](https://github.com/ShiningRay/troupe-js/blob/main/docs/VERIFICATION.md)

- [#1 Show 有界重试与持久流语义](https://github.com/ShiningRay/troupe-js/issues/1)
- [#2 PG optional Provider 依赖](https://github.com/ShiningRay/troupe-js/issues/2)
- [#3 PostgreSQL/POSIX 故障门禁](https://github.com/ShiningRay/troupe-js/issues/3)
- [#4 热替换兼容检查范围](https://github.com/ShiningRay/troupe-js/issues/4)

文档提交：`820882356567d88614708beed93f77ac3e1a60d5`。

## Elixir — ShiningRay/troupe-elixir

方案：[Orleans 差距](https://github.com/ShiningRay/troupe-elixir/blob/main/docs/ORLEANS_GAP.md) · [路线](https://github.com/ShiningRay/troupe-elixir/blob/main/docs/ROADMAP.md) · [验证](https://github.com/ShiningRay/troupe-elixir/blob/main/docs/VERIFICATION.md)

- [#1 所有权前迁移写](https://github.com/ShiningRay/troupe-elixir/issues/1)
- [#2 Roster 角色校验与多节点验收](https://github.com/ShiningRay/troupe-elixir/issues/2)
- [#3 共享 Props/Cue/fencing 闭环](https://github.com/ShiningRay/troupe-elixir/issues/3)

文档提交：`73ff4edd28f2d772ad1c6c6912b44997a0adb7ee`。

## Ruby — ShiningRay/troupe-rb

方案：[Orleans 差距](https://github.com/ShiningRay/troupe-rb/blob/main/docs/ORLEANS_GAP.md) · [路线](https://github.com/ShiningRay/troupe-rb/blob/main/docs/ROADMAP.md) · [验证](https://github.com/ShiningRay/troupe-rb/blob/main/docs/VERIFICATION.md)

- [#1 Ruby 4 logger 依赖](https://github.com/ShiningRay/troupe-rb/issues/1)
- [#2 Rehearsal namespace 验收绕过旧 Props](https://github.com/ShiningRay/troupe-rb/issues/2)
- [#3 非逐级迁移](https://github.com/ShiningRay/troupe-rb/issues/3)
- [#4 Minitest 6/Ruby 支持矩阵](https://github.com/ShiningRay/troupe-rb/issues/4)
- [#5 共享存储与真实接管](https://github.com/ShiningRay/troupe-rb/issues/5)

文档提交：`2ee0a5864d7aa1a422758a0e70e37225a9acaa1a`。

## Crystal — ShiningRay/troupe-cr

本轮只交付方案与脚手架，见 [DESIGN](https://github.com/ShiningRay/troupe-cr/blob/main/DESIGN.md) 和 [PLAN](https://github.com/ShiningRay/troupe-cr/blob/main/PLAN.md)。实际提交以仓库 main 为准。

- [#1 Rehearsal(Manual) 上 typed Agent 阻塞缺警示（文档/易用性）](https://github.com/ShiningRay/troupe-cr/issues/1)
- [#2 OutboxDispatcher 批量/后台派发建议](https://github.com/ShiningRay/troupe-cr/issues/2)——已由 [troupe-gateway](https://github.com/ShiningRay/troupe-gateway) 在消费侧先行落地，[跟进评论](https://github.com/ShiningRay/troupe-cr/issues/2#issuecomment-6897214063)

## 首个外部消费者 — ShiningRay/troupe-chat

[troupe-chat](https://github.com/ShiningRay/troupe-chat)：troupe.cr 房间 actor + [tessell](https://github.com/ShiningRay/tessell) 自绘 GUI 的聊天室，ADR-0007 的实证来源。发现的上游缺陷：

- [tessell #52 GLBackend#draw_text 增量提交不渲染](https://github.com/ShiningRay/tessell/issues/52)
- [tessell #53 Kit::Text#truncate 渲染 String::Builder 对象](https://github.com/ShiningRay/tessell/issues/53)

本索引记录创建时状态，Issue 是否完成以对应仓库当前状态为准。
