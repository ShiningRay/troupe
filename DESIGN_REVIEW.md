# DESIGN_REVIEW —— 开发复盘：已知问题与设计取舍

> 状态：v1 · 2026-09-16（对应 Troupe.rb 0.1.0，78 项测试全绿后的诚实盘点）
> 本文是给维护者和使用者的真话清单：哪些是缺陷、哪些是工效债、哪些是我们替原设计文档做的决定。
> 设计语义的权威来源仍是 Troupe.js 的 DESIGN.md；实现映射见 [DESIGN_NOTES.md](DESIGN_NOTES.md)。

## 1. 结构性问题（缺陷级，建议优先处理）

### 1.1 线程模型撑不起原设计的容量叙事 ⚠ 核心张力

Node 版的容量事实（88k activations/s、6.3KB/Actor）建立在"Actor = 闭包 + 队列"之上；Ruby 版每个在场 Actor 是一条 OS 线程（懒启动、下场回收）。直接后果：

- 容量上限从"百万级 Promise"降到"数千级线程"；`activation_limit`（默认 10 000/Stage）实为线程保护阀。
- **Actor 互调与远程转发同步阻塞线程**：A→B 互调叠线程栈；转发占用 worker 池（默认 32）直到目标 settle——慢目标会打满池子、殃及无关调用（JS 里挂起的 Promise 几乎免费，这里每次挂起都是一条真线程）。
- GVL 使 CPU 密集的 Turn 全进程串行，多核只能靠多进程（这一点与原设计"一进程一 Stage"反而更一致）。

**可能的出路**（战略选型，未排期）：Fiber 方案——每 Cell 一个 Fiber、小线程池驱动、配合 `async` 生态非阻塞 I/O。密度可接近 Node，但要求用户代码全程非阻塞，破坏"普通阻塞 Ruby 代码直接写"的零成本优势。这是"简单优先"与"容量"的二选一，v1 选了前者。

### 1.2 Improv/ReadOnly 的交错粒度与 JS 版语义不同 ⚠ 语义偏差

JS 只在 `await` 点交错：不含 await 的 `@ReadOnly` 方法是原子的。Ruby 线程在**任意位置**被 GVL 时间片抢占：组合矩阵名义保留，交错粒度更粗。**标注 `improv` 前需要的状态容忍度比 JS 版更高，不是相同**。DESIGN §5.4 的警告在 Ruby 版要加倍看待。（修法：annotated 走 Fiber 化执行才可能逼近 await 点语义。）

### 1.3 PStore 每次保存全量落盘 ⚠ 最弱的实用决策

零 gem 依赖目标绑架了存储选型：全部 Actor 的 Props 存**一个** `props.pstore`，PStore 每次事务 Marshal 整个文件——`save_props` 的代价是 O(全部状态) 而非 O(本 Actor 状态)。演示与测试没问题，认真使用必须换。候选修法：

1. 按 Actor 分文件（`props/<ns>/<role>/<name>.pstore`）——最小改动；
2. 把 `sqlite3` 定为软性默认（检测到 gem 即用，否则回退 PStore 并告警）；
3. Postgres 共享 PropStore（多节点生产本来就绕不开）。

另注：pstore 自 Ruby 3.5 起移出 default gems，未来版本需显式声明依赖或换实现。

### 1.4 `module Troupe` 与 `class Troupe` 同名遮蔽 ⚠ 已踩雷，隐患仍在

gem 内部词法解析中，裸 `Troupe` 常量优先命中 `Troupe::Troupe`（集群句柄类）。已实际造成 bug：`Troupe.const_get("UnknownMethodError")` 查不到、错误分类静默降级为普通 `CallRejectedError`（现以 `::Troupe` 限定修复）。但每个 `Troupe::X` 引用都离同一个雷一步。**修法**：句柄类改名 `Troupe::Runtime`（或 `Cluster`），模块只留门面 `Troupe.form`——建议在下一个 minor 版本做，含一次 breaking rename。

## 2. 与 Ruby 理念的摩擦（工效债）

### 2.1 Props 字符串键：日常最大的别扭

`props["items"]` 写起来像 JSON 不像 Ruby（Symbol 键过边界归一为字符串）。这是"本地/远程/Rehearsal 同一编解码边界"原则的代价，Marshal 保 Symbol 会破坏边界一致性。候选方向（按侵入度）：

- props 解码时 symbolize + 文档约定（快，但键来源分两套）；
- 带 schema 的 Props 包装对象（`props.items` / 类型化读取）——倾向于此，同时缓解"JSON 可解析 ≠ 满足结构"的老问题。

### 2.2 关键字参数被整体拒绝，不 Ruby

`def reserve(request_id:, qty:)` 是最自然的 Ruby 签名，现为 `SerializationError`。为 JSON 线路纯粹性牺牲了最主要的调用习惯。**修法**：kwargs 打包为保留信封参数（末位 `__kw`）随线路传输，被调端展开，arity 校验计入；保持本地/远程一致。

### 2.3 method_missing Agent 的内省失真

pry/debugger 补全、`instance_methods` 看不到 RPC 面；白名单外成员在派发时才报错。更 Ruby 的做法：`cast()` 时按白名单 `define_method` 生成匿名代理类——对象诚实回答自身能力、无 method_missing 分派开销、错误在 cast 时即可静态暴露。

### 2.4 其余小项

- `performs!` 的进程级默认注册表是全局可变状态；靠 `form()` 快照兜底，多 troupe 测试仍需自觉显式注册。
- 本地调用复用**同一异常对象**在调用方线程 re-raise，会改写其 backtrace——已知 Ruby 病，影响仅限诊断。
- 信号处理：trap 上下文不能碰 Mutex，`shutdown!` 必须经 `Thread.new`（示例已示范，但这是用户必须知道的 Ruby 约束）。
- Trace 订阅每订阅者一线程 + 队列，CLI 异常退出时依赖进程回收，长生命周期进程需注意 `close`。

### 2.5 `save_props` 的返回值是隐性合同

Ruby"末表达式即返回值"使用户方法常以 `save_props` 结尾，返回值会过 Codec 边界——初版返回 `StoredProps` 直接炸调度线程（已改为返回 revision 整数）。JS 里 await 丢弃返回值故无感；Ruby 里"显式保存"模式的返回值语义绕不开。文档已写死"返回新 revision"，勿改回对象。

## 3. 原设计文档（Troupe.js DESIGN.md）的歧义 —— 我们替它做了决定，待回写确认

| # | 歧义 | Troupe.rb 的决定 | 建议 |
|---|---|---|---|
| 1 | §5.1 流水线写"offStage() → saveProps"，但 §7.3 攒批模式（dirty_ops + flush Cue）只有"offStage **不**自动保存"才有完整意义——否则丢失窗口仅存在于硬崩溃 | 排空时钩子之后**框架必定保存一次**；drop-shop 的 `dirty_ops` 因此只对崩溃场景有意义 | 在 Troupe.js DESIGN 写死语义；若改为"不自动保存"，Ruby 版给 `save_on_drain` 配置 |
| 2 | "内存 Cue 随实例下场消失"——消失的是 Cue 还是内存状态？排空自动保存使内存计数同样落盘并随下次登台恢复 | Cue 消失；内存突变因排空保存而持久 | 同上，与 #1 联动定义 |
| 3 | Troupe.js 自身如遇 §9.5 swap 守则、容量事实在 Ruby 的对应物——Ruby 无 `setPrototypeOf`，L1/L2 热替换需完全不同的机制（class 方法表替换 + 常量卸载），未开工 | `recycle`（下场重登）路径天然可用；swap 无对应物 | 在 Troupe.js 文档标注 L1/L2 的语言前提 |

## 4. 测试的时序脆弱性

写饥饿、执行占用等验收测试依赖真实 sleep 与阈值断言（已连续 5 轮全绿），在慢 CI 上仍可能 flake。根治需要虚拟时钟或确定性调度器（Fiber 化执行模型的副产物），暂列为已知限制；`wait_until` 轮询已按宽松阈值设计。

## 5. 反过来：Ruby 更顺的地方（保持）

- RPC 白名单 = `public_instance_methods(false) − 生命周期钩子`，一行即得，比装饰器方案干净；
- 类宏 DSL（`role_id` / `intermission` / `initial_props` / `improv`）贴合 Ruby 惯例；
- xxh32 得益于 Integer 无溢出，实现零心智负担；
- Mutex + ConditionVariable 实现 FIFO 带超时队列比预期直接；
- minitest + 线程让并发验收测试直白可写。

## 6. 结论与动手顺序

| 优先级 | 项 | 性质 |
|---|---|---|
| ① | PropStore 摆脱 PStore 全量写（分文件 / sqlite3 软默认） | 缺陷 |
| ② | 消除 `Troupe::Troupe` 遮蔽（句柄类改名） | 缺陷 |
| ③ | Props 符号键 / typed props 工效方案 | 工效债 |
| ④ | kwargs 线路支持（信封参数） | 工效债 |
| ⑤ | Fiber 执行模式作为可选 StageManager（含虚拟时钟测试收益） | 战略选型 |

①② 建议进 0.2.0；③④ 随 0.3.x；⑤ 独立实验。§3 的三项歧义决定应回写 Troupe.js DESIGN.md 后两边对齐。
