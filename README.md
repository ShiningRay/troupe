# Troupe.rb

> Troupe.js（[DESIGN](../troupejs/DESIGN.md) / [PLAN](../troupejs/PLAN.md)）的 Ruby 版本：面向 Ruby 的 **Virtual Actor** 框架，思想对标 Microsoft Orleans 与 EA Orbit，命名与语义全面沿用"剧团（Troupe）"隐喻。**运行时零 gem 依赖**（纯 stdlib）。

## 核心语义

- **永远存在**：Actor 无需显式创建，用 `(role, stageName)` 全局寻址
- **按需激活**：第一条 Call 到达时在集群某 Stage 登台；生产集群激活前置所有权检查（租约 + fencing token）
- **自动钝化**：空闲超过 Intermission 自动下场，Props 归还 PropStore
- **Turn-based 严格串行**：一次一条 Call，天然无锁；`improv`/`read_only` 标注方法按组合矩阵交错
- **位置透明**：调用方持有 Agent，不关心目标在哪个 Stage；环漂移期自动转发（跳数上限 2）
- **故障即重激活**：Stage 死亡后，下一条 Call 让 Actor 在健康 Stage 重新登台（共享存储 + 所有权接管）

| 概念 | 命名 | | 概念 | 命名 |
|---|---|---|---|---|
| 集群 | **Troupe** | | 持久化状态 | **Props** |
| 节点/进程 | **Stage** | | 存储 Provider | **PropStore** |
| 虚拟 Actor | **Actor** | | 定时器/提醒 | **Cue / Reminder** |
| 代理引用 | **Agent** | | 空闲超时 | **Intermission** |
| 激活/钝化 | **OnStage / OffStage** | | 可重入/只读 | **Improv / ReadOnly** |
| 寻址路由 | **Playbill**（HashRing）| | 测试集群 | **Rehearsal** |
| 成员管理 | **Roster** | | 管理内省 | **Director**（CLI 瘦客户端）|
| 邮箱/消息 | **CallBoard / Call** | | 流 | **Show**（进程内）|

## 快速开始

```ruby
require "troupe"

class CartActor < Troupe::Actor
  role_id "cart"                    # 默认 = 类名去 "Actor" 后缀；持久业务建议显式声明
  intermission "10m"                # 默认 5m
  initial_props { { "items" => [] } }  # 首次登台的初始状态（字符串键：JSON 边界语义）

  def on_stage = puts "[cart:#{stage_name}] 登台"
  def off_stage
    save_props                      # 下场归还 Props
  end

  def add(item)
    props["items"] << item
    save_props                      # 持久成功：CAS 提交成功后才返回
  end

  def peek = props["items"].length
end

troupe = Troupe.form(actors: [CartActor])     # 显式注册（推荐）
cart = troupe.cast(CartActor, "user-123")     # Agent：类型面只有 RPC 方法
cart.add({ "sku" => "sku-1", "qty" => 1 })
cart.peek # => 2
```

运行示例：

```bash
ruby examples/minimal/cart.rb        # DESIGN §3.1 最小示例
ruby examples/drop_shop/shop.rb      # §10.3 限量发售（幂等重放/同键不同参数拒绝）
ruby bin/troupe status               # CLI（先起一个节点）
```

双节点集群：

```bash
TROUPE_PORT=7301 ruby examples/cluster/node.rb
TROUPE_PORT=7302 TROUPE_SEEDS=127.0.0.1:7301 ruby examples/cluster/node.rb
ruby bin/troupe --to 127.0.0.1:7301 ps     # 在场演员（跨 Stage 聚合）
```

## 框架承诺（每条都有对应验收测试）

| 承诺 | 语义 | 测试 |
|---|---|---|
| 激活 single-flight | 并发首调只激活一次 | `test_single_flight_activation…` |
| 严格串行 | 上一 Turn settle 前不取下一 Call | 50 并发 `bump` 无交错 |
| 排队过期不执行 | deadline 已到的排队 Call 直接拒绝，无副作用 | `test_queued_expired…` |
| 响应期限 ≠ 执行占用 | 调用方超时后旧任务继续跑完，后续 Call 不与其交错 | `test_timeout_releases_caller…` |
| 保存失败实例失效 | 下次调用从最后已提交快照继续，不基于未提交状态运行 | `test_save_failure_invalidates…` |
| 幂等恢复 | 同 requestId 同参数重放原结果；同键不同参数拒绝 | `examples/drop_shop` |
| 结果未知 ≠ 失败 | 超时/断连只代表结果未知；框架不自动重试 | `test_remote_deadline…` |
| 所有权 fencing | 接管后 epoch 单调递增，旧实例写入被存储拒绝 | `test_takeover_rejects_old_owner…`、`test_stage_death_failover…` |
| 持久提醒 | 下场后仍触发并重新登台；租约到期重投（至少一次） | `test/cue_test.rb` |
| 信任边界 | 生命周期钩子/基类成员不可经 RPC；畸形帧可控拒绝 | `test_whitelist_enforced_on_wire`、`test_malformed_frame…` |

运行全部测试：

```bash
bundle install
bundle exec rake test   # 78 runs
```

## 配置（显式传参 > 环境变量 > 约定默认值）

| 旋钮 | 默认 | 环境变量 |
|---|---|---|
| 部署模式 | `dev`（loopback、端口被占自动换） | `TROUPE_MODE` |
| Stage 监听 | `127.0.0.1:7300` | `TROUPE_PORT` / `TROUPE_HOST` / `TROUPE_ADVERTISE` |
| seeds | 空 = 自成一团 | `TROUPE_SEEDS`（逗号分隔） |
| PropStore | PStore `./.troupe/props.pstore`（进程级持久）；`:memory` / `:sqlite`（需 sqlite3 gem） | `TROUPE_PROPS_DIR` / `TROUPE_PROPSTORE` |
| 命名空间 | 当前目录名 | `TROUPE_NAMESPACE` |
| Call 超时 / Intermission / Cue tick | 30s / 5m / 1s | — |
| 优雅停机 | SIGTERM 由应用捕获后调 `troupe.shutdown!`；宽限 10s | `TROUPE_SHUTDOWN_GRACE` |
| Director | 仅 loopback；远程需 token | `TROUPE_ADMIN_TOKEN` |
| Rehearsal | `Troupe::Testing.rehearsal(actors: [...])` 全内存 | `TROUPE_ENV=test` |

## CLI：`bin/troupe`

`status` `roster` `ps` `inspect` `call` `off` `ring` `cues` `metrics` `tail` `top`，支持 `--to host:port`、`--json`。CLI 是 Director 的瘦客户端——客户端永远只连一个点。

## 实现范围（对照 Troupe.js PLAN）

已实现：**M1** 严格串行运行时 + PropStore 合同（CAS/迁移/校验）；**M2** 本地持久化（PStore）+ TCP 集群（长度前缀 JSON、白名单、背压、畸形帧防护）+ HashRing（纯 Ruby xxh32，160 vnodes）+ 误投转发；**M3** 所有权（租约 + 单调 epoch + fencing）+ Roster（gossip 反熵 + ping/ACK 探测 + 终态不可复活）；**M4** 持久 Cue（CueStore + claim/lease/statusVersion CAS + cron）+ Director/CLI；**M5** 交错执行（组合矩阵 + 写饥饿防护）；**M6** Trace 总线（环形缓冲 + 采样 + 订阅）；**M7** Show（进程内 pub/sub）。

路线图（见 [DESIGN_NOTES.md](DESIGN_NOTES.md)）：Postgres 共享 PropStore、BoxOffice、Booth、热重载/热替换（Ruby 无 `setPrototypeOf`，L1/L2 需另设计）、Show 跨节点转发、Extra。

## 已知边界

- **单个热点 Actor 只有一个串行通道**：加 Stage 只能分摊不同 Actor 的负载（容量事实，DESIGN §5.3）
- **每在场 Actor 一个调度线程**：Ruby 线程成本高于 JS Promise，高 churn 场景建议调低 Intermission 或提高 `activation_limit` 前评估内存
- **PStore/SQLite 均为进程级持久**：多节点生产的共享 PropStore（Postgres）未实现前，集群故障恢复仅在共享内存 Store（同进程多 Stage）或同机单进程内成立
- 本地调用默认走同一 JSON 编解码边界：Hash 键归一为字符串、Symbol → String、Time → ISO 8601；`local_call_by_reference: true` 可显式关闭复制换性能（语义分叉自担）
