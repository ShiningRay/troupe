# DESIGN_NOTES —— Troupe.js → Ruby 的设计适配

> 本文记录 Ruby 版相对 Troupe.js（DESIGN.md v2 / PLAN.md v4）的每一个重要设计映射与取舍。语义承诺以原文档为准；这里只讲"在 Ruby 里怎么成立"。
> 已知问题、与 Ruby 理念的冲突及优先级路线见 [DESIGN_REVIEW.md](DESIGN_REVIEW.md)。

## 1. 执行模型：事件循环 → 每 Cell 一条调度线程

Node 版的严格串行靠"事件循环 + 上一 Promise settle 前不取下一 Call"。Ruby（MRI）没有单线程事件循环，线程又会在 I/O 点真实交错，因此：

- 每个 `(namespace, role, stageName)` 的在场单元（Cell）持有 **FIFO CallBoard**（Mutex + ConditionVariable 实现的带超时 `pop`）和 **一条专属调度线程**（首次入队时懒启动，下场时退出）。
- 调度线程逐条执行 Call = 严格串行；激活天然 single-flight（队列语义）。
- **响应期限与执行占用分离**（DESIGN §5.1 的核心契约）的达成方式：调用方在 ResponseBox 上带 deadline 等待，超时只是"放弃等待"，绝不取消执行线程；下一条 Call 由同一线程在上一条 settle 后才开始。
- **排队过期不执行**：调度线程取出 Call 时先查 deadline，过期直接回 `CallTimeoutError`，未产生副作用。
- 排空（Intermission 到期 / 管理下场 / 失去所有权 / 停机）与激活互斥：draining 状态下新请求在 StageManager 层等待旧 Cell 从在场表消失后重新解析（等待排空完成后重新激活，或显式拒绝）。
- 调度线程意外崩溃时：先 settle 当前 Call（不悬挂调用方），再 fail 全部排队 Call 并失效实例——下次调用从最后已提交快照重新激活。

容量事实随之变化：Node 的"6.3KB/Actor"变成"每在场 Actor 一个 Ruby 线程"（约几十 KB 堆内存）。高 churn 场景应调低 Intermission；`activation_limit`（默认 10 000/Stage）保护线程总量。

## 2. 交错执行（Improv/ReadOnly）：组合矩阵 + 写饥饿防护

- 标注：`improv :m` / `read_only :m` 类宏（等价 `@Improv`/`@ReadOnly`）。校验延迟到注册时（DSL 顺序自由），`form()` 时尽早报错。
- 组合矩阵（§5.4）：未标注 = strict，仅当在飞为 0 时启动；annotated 之间可交错——annotated Call 由调度线程派发到**独立线程**执行。
- **写饥饿防护**：单调度线程是天然的守门员——strict 被取出后调度线程阻塞等待在飞 annotated 清零，期间不可能启动新 annotated；strict 之间保持 FIFO。
- ⚠ 与 JS 相同的警告：Ruby 线程不提供跨方法的业务原子性，交错窗口内其它调用可见 Props 中间态（且 MRI 的 GVL 时间片让 CPU 段也会交错）。标注前必须确认方法容忍中间态。

## 3. 编解码边界：JSON 为准，本地默认复制

- `Codec`（DESIGN §6.1）：本地、远程、Rehearsal 三种模式走**同一边界**。约定：Hash 键归一为字符串、Symbol → String、Time/Date → ISO 8601、循环引用与不支持的类型抛 `SerializationError` 并指引 DTO。
- Ruby 特有差异（相对 JS）：**Bignum 原生无损**（无 JS BigInt 精度问题）；String 键序即插入序。
- 本地调用默认深拷贝参数与结果；`local_call_by_reference: true` 显式关闭（语义分叉自担）。
- 框架内部约定：`save_props` 返回**新 revision（整数）**——用户方法常以 `save_props` 结尾，返回值会过 Codec 边界，返回存储对象会破坏可序列化合同。

## 4. 持久化：PStore 顶替 node:sqlite

| 实现 | 持久级别 | 说明 |
|---|---|---|
| `MemoryPropStore` | 无 | Rehearsal/测试；CAS/fencing 合同与文件实现完全一致 |
| `PStorePropStore`（默认） | 进程级 | stdlib PStore：事务 + 整文件落盘；`./.troupe/props.pstore` 首次用到才建 |
| `SqlitePropStore`（可选） | 进程级 | 需 sqlite3 gem；CAS 以单条 UPDATE 实现（对标 node:sqlite） |
| PostgresPropStore | 节点级 | **路线图**；当前选择连接串会得到明确报错 |

- revision（并发修订，CAS 用）与 schema_version（结构版本，迁移用）分离；`create` 仅当不存在时成功；冲突抛 `ConflictError`。
- 迁移：`schema_version` 落后于类声明时逐级调 `migrate_props(stored, from_version)`，迁移产物 CAS 提交；迁移失败明确报错（角色 + stageName + 版本），实例失效。
- **多进程不要共用同一个 PStore/SQLite 文件**（进程级锁，非跨进程安全）——这是"进程级持久"的边界，与 node:sqlite 定位一致。

## 5. 所有权与 fencing

- 所有权记录存于 PropStore（共享存储合同）：`(ns, role, stageName) → {owner, epoch, lease_until}`。
- **激活前置**：CAS 获取（他人有效租约 → 等待至 `ownership_acquire_timeout` 后 `OwnershipError`）；获取/接管时把 Props 记录的 fence 前移到新 epoch。
- **释放即墓碑**：graceful 释放不清记录，只把 `lease_until` 置 0——保证 epoch 对 `(ns, role, stageName)` **单调不回退**，旧进程复活后的写入仍会被拒。
- Stage 级心跳线程按租约 1/3 周期续租；续租失败 = 被顶替 → 立即停止接单并排空，其落盘保存因 fence 过期被存储拒绝 → 实例失效（DESIGN §6.5 的"失去所有权"全链路）。
- fencing 的局限照搬原文：租约挡不住"暂停后恢复的旧代码"继续产生外部副作用——外部接收方需校验 token（`actor.fencing_token`）或使用 outbox + 业务幂等。

## 6. 集群：HashRing / Roster / 转发

- 寻址：`xxh32(ns:role:stageName)`（**纯 Ruby 实现**，与 TS 版同算法同向量）→ HashRing（160 vnodes，bsearch 命中）。环视图跟随 Roster 版本惰性重建。
- Roster（传播/探测分离，非完整 SWIM）：
  - 合并规则：incarnation 更大直接采纳（重启即新身份）；同 incarnation 下 `dead/left` 为**终态**——反复转发的旧 alive 不能复活已确认死亡的成员；suspect 可被在场证据反驳。
  - 探测：周期 ping 环序相邻 k=2 个成员并等 ACK；超时 suspect，`SUSPECT_TIMEOUT` 未反驳 → confirmed dead（终态、摘环、保留墓记录）。
  - dev 模式 seeds 全部不可达：明确提示"自成一团"；production 必须显式 advertise 且 `join_timeout` 内入团成功，否则启动失败。
- 误投转发：环漂移期收到不归自己的 Call → 按当前视图转发，跳数上限 2，超限显式拒绝（防环）。
- 传输：4 字节小端长度前缀 + JSON；帧长上限 8MB；远端 worker 池（默认 32）+ 队列上限构成 in-flight 背压；畸形帧可控拒绝（连接关闭、进程不崩）；写入统一转二进制避免 UTF-8/ASCII-8BIT 拼接异常。
- 信任边界（§6.1）：接收端始终校验方法白名单（生命周期钩子/基类成员/双下划线内部方法不可经 RPC）；`TROUPE_CLUSTER_TOKEN` 做节点加入凭证；Director 仅 loopback 或 `TROUPE_ADMIN_TOKEN`。

## 7. Cue 与持久提醒

- 内存 Cue：随实例下场消失（调度线程持有，排空即取消）。
- 持久提醒：`schedule_reminder(name, spec, payload:)` → CueStore upsert（重复注册幂等，不重置 next_due）；到期查询 → 原子 `claim`（租约）→ `on_cue(name, payload)` 作为一条 internal Call 进 CallBoard（受同一串行约束）→ `complete`（statusVersion CAS 裁决注销竞争）。
- **至少一次**：执行超过租约 → 重新认领重投（业务幂等去重）；错过多个周期默认跳过、按当前时刻计算下一次（不补发风暴）。
- spec 支持 `every:` 间隔（`"0.2s"`/`"1h"`）与 5 字段 cron（纯 Ruby 解析器：`* , - /`、英文缩写、vixie 的 dom/dow 取或语义）。
- 无持久 CueStore 时 `schedule_reminder` 显式报错。

## 8. 观测

- Trace 总线：每次调用产事件（调用方→被调方、方法、耗时、结果分类），环形缓冲 1 万条 + 采样率 + 字节预算自动降采样 + 订阅（慢订阅者丢弃不阻塞调用路径）。`bin/troupe tail` 即订阅者。
- 每角色计数器与延迟环形直方图（p50/p99/max，固定内存）。
- Director：每 Stage 内建系统角色（`__director__` 保留前缀，用户 Repertoire 拒绝双下划线角色名），集群查询扇出聚合（含本 Stage），管理调用走同一 StageManager（白名单适用、不旁路串行规则）。

## 9. 明确的范围外（相对 Troupe.js）

| 项 | 原因 / Ruby 版取向 |
|---|---|
| PostgresPropStore（共享持久） | 路线图首选；在此之前集群故障恢复仅在共享内存 Store（同进程多 Stage）成立 |
| L1/L2 热更新 | JS 的 `Object.setPrototypeOf` 红利不存在；Ruby 等价物需 `class` 级方法表替换 + 常量卸载，独立实验，未开工。`recycle`（下场重登）路径天然可用 |
| BoxOffice / Booth | 未实现；Director 协议已就绪，HTTP 网关与 Web 界面可后续挂接（`Troupe::Edge`（WEBrick）已提供 /healthz、/metrics、/call） |
| Show 跨节点转发 / Audience 回调引用 | 首实现进程内 pub/sub（消息过同一 Codec 边界） |
| Extra（无状态池化） | 未实现 |
| OTel 打通 | Trace 事件已结构化，适配器后续按需 |
| kwargs / block 跨 RPC | 明确拒绝并指引（JSON 边界只传位置参数数组）——本地远程行为一致优先 |
