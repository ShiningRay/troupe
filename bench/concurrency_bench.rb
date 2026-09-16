# frozen_string_literal: true

# Troupe.rb 并发能力基准（横向对比版）
# 运行：ruby bench/concurrency_bench.rb
#
# P1 调用管线开销：直接调用 / Fiber ping-pong / 原生 Thread ping-pong / Ractor ping-pong / Troupe 调用 / Troupe 持久写
# P2 单演员串行性：1 vs 8 客户端打同一演员 → 排队效应（吞吐不增、延迟线性上升）
# P3 I/O 重叠横向对比（sleep 10ms × 320 次，并发 C ∈ {16, 80, 320}）：
#      Troupe strict（串行基线）/ Troupe improv / 原生 Thread 池 / Fiber Scheduler（事件循环）/ Ractor 池
# P4 CPU 密集横向对比（零分配整数混合；分配型任务会撞 Ractor 全局 GC 锁）：串行 / Thread 池（GVL 封顶）/ Ractor 池（真并行）
# P5 并发单元驻留成本（100 个单元挂起待命）：Troupe 演员 / 原生 Thread / Fiber / Ractor
#
# 每个场景采集：吞吐、延迟分位、进程 CPU 占用（GetProcessTimes）、
# 累计分配对象数（GC.stat）、RSS 工作集增量（tasklist）、峰值线程数。
#
# 平台说明：
# * Windows 定时器粒度 ≈15.6ms：sleep(10ms) 实际 ≈15.6ms，影响所有机制的绝对值（公平地）。
# * CPU% 可 >100%：多线程/Ractor 并发使用核心；MRI 的 GVL 下 CPU 密集方法只有 Ractor 能真并行。
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "troupe"
require "logger"
require "fiddle"
require "fiber"
require "etc"

Warning[:experimental] = false # Ractor 实验性告警

Troupe::Log.logger.level = Logger::ERROR

MONO = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

# ---- 资源采集 ----

module Res
  K32 = Fiddle.dlopen("kernel32")
  GPT = Fiddle::Function.new(K32["GetProcessTimes"], [Fiddle::TYPE_VOIDP] * 5, Fiddle::TYPE_INT)
  GCP = Fiddle::Function.new(K32["GetCurrentProcess"], [], Fiddle::TYPE_VOIDP)

  module_function

  # 进程累计 CPU 时间（内核 + 用户态；粒度 ≈15.6ms）
  def cpu_s
    c = "\0".b * 8; e = "\0".b * 8; k = "\0".b * 8; u = "\0".b * 8
    GPT.call(GCP.call, c, e, k, u)
    (k.unpack1("Q") + u.unpack1("Q")) / 1e7 # 100ns → s
  end

  # 进程工作集（KB）；tasklist 输出形如 "ruby.exe","1234","Console","1","18,096 K"
  def rss_kb
    m = `tasklist /FI "PID eq #{Process.pid}" /FO CSV /NH`.match(/"([\d.,]+)\s*K"/i)
    m ? m[1].delete(",").to_f : Float::NAN
  end
end

# ---- 计时 / 采样 ----

Snap = Struct.new(:cpu, :rss, :allocs, :threads, :ractors)

def snap!
  GC.start(full_mark: true, immediate_sweep: true)
  Snap.new(Res.cpu_s, Res.rss_kb, GC.stat(:total_allocated_objects), Thread.list.size, Ractor.count)
end

# 执行 block：返回 wall / cpu%（进程 CPU 时间占比，可 >100%）/ allocs / RSS 增量 / 峰值线程
def measure
  GC.start(full_mark: true, immediate_sweep: true)
  s0 = snap!
  peak = Thread.list.size
  stop = false
  sampler = Thread.new do
    until stop
      peak = [peak, Thread.list.size].max
      sleep 0.005
    end
  end
  wall0 = MONO.call
  yield
  wall = MONO.call - wall0
  stop = true
  sampler.join
  {
    wall: wall,
    cpu: Res.cpu_s - s0.cpu,
    allocs: GC.stat(:total_allocated_objects) - s0.allocs,
    rss: Res.rss_kb - s0.rss,
    peak_threads: peak
  }
end

def pct(sorted, p)
  return 0.0 if sorted.empty?

  sorted[[(p / 100.0 * (sorted.length - 1)).round, sorted.length - 1].min]
end

# jobs = [[agent, 次数], ...]：每个 job 一条客户端线程，串行同步调用；返回 [wall, 延迟数组(ms)]
def run_load(jobs, &call)
  lats = Array.new(jobs.length) { [] }
  threads = jobs.each_with_index.map do |(agent, n), i|
    Thread.new do
      n.times do
        t0 = MONO.call
        call.call(agent)
        lats[i] << (MONO.call - t0) * 1000.0
      end
    end
  end
  t0 = MONO.call
  threads.each(&:join)
  [MONO.call - t0, lats.flatten.sort]
end

# ---- 被测演员（Troupe 侧）----

class PingActor < Troupe::Actor
  intermission "30m"
  initial_props { { "counter" => 0 } }

  # 纯管道开销：无状态、整数返回（Codec.copy 对 Integer 走零拷贝快路径）
  def ping(i) = i

  # 持久写路径：save_props = 编解码复制 + CAS 提交成功后才返回（DESIGN §7.1）
  def incr
    props["counter"] += 1
    save_props
    props["counter"]
  end
end

class IoStrictActor < Troupe::Actor
  intermission "30m"

  def io_work(ms) = sleep(ms / 1000.0)
end

class IoImprovActor < Troupe::Actor
  improv :io_work # @Improv 等价：可与其它调用交错，不独占 turn（DESIGN §5.4）

  def io_work(ms) = sleep(ms / 1000.0)
end

# ---- 对照实现 1：Fiber Scheduler（最小 sleep 事件循环）----

class SleepScheduler
  def initialize = @wake = [] # [[唤醒时刻, Fiber], ...]

  def kernel_sleep(duration = nil, ...)
    @wake << [MONO.call + (duration || 0), Fiber.current]
    Fiber.yield # 交回调度循环
  end

  def block(blocker, timeout = nil) = Fiber.yield
  def unblock(blocker, fiber) = (@wake << [MONO.call, fiber]); nil
  def io_wait(io, events, timeout = nil) = events
  def io_read(io, buf, len) = -1
  def io_write(io, buf, len) = len
  def process_wait(pid, flags) = [pid, 0]
  def address_resolve(hostname) = [hostname]
  def timeout_after(duration, klass, message) = yield
  def fiber_interrupt(fiber, exception) = raise exception
  def close = nil

  def run
    until @wake.empty?
      now = MONO.call
      ready, later = @wake.partition { |t, _| t <= now }
      @wake = later
      sleep([@wake.min_by(&:first).first - now, 0.001].max) if ready.empty?
      ready.each { |_, f| f.resume }
    end
  end
end

# C 并发的 Fiber 重叠：每批 C 个 fiber，批内全部挂起后由调度循环唤醒
def fiber_overlap(count, concurrency, ms, sched)
  count.times.each_slice(concurrency) do |batch|
    fibers = batch.map { Fiber.new(blocking: false) { sleep(ms / 1000.0) } }
    fibers.each(&:resume) # 各自跑到 kernel_sleep 挂起
    sched.run
  end
end

# ---- 对照实现 2：Ractor 池（Port 语义：创建者才能 receive，任何人可 send）----
# 握手协议：worker 自建收件口，经 main 的 reply 口回传；:stop 哨兵停机

# CPU 密集任务：xorshift 整数混合循环——零分配（分配型任务会撞 Ractor 的
# 全局 GC 锁而失去并行意义），运行时标定单任务 ~40ms
# 注意：Windows（LLP64）Ruby 的 Fixnum 立即数仅 ±2^30（long=32 位），
# 状态字必须留在 13 位以内才能保证所有中间值零分配；Linux 64 位无此限制。
module CpuTask
  MASK = (1 << 13) - 1

  def self.run(iters)
    x = 0x9E37
    i = 0
    while i < iters
      x ^= x << 7
      x &= MASK
      x ^= x >> 3
      x ^= x << 5
      x &= MASK
      i += 1
    end
    x
  end
end

def ractor_pool(count)
  reply = Ractor::Port.new
  workers = Array.new(count) do
    Ractor.new(reply) do |rp|
      my_in = Ractor::Port.new
      rp.send(my_in)
      loop do
        msg = my_in.receive
        break if msg == :stop
        # msg = ["io", ms] 或 ["cpu", n]
        rp.send(msg[0] == "io" ? (sleep(msg[1] / 1000.0); :ok) : CpuTask.run(msg[1]))
      end
    end
  end
  [workers, Array.new(count) { reply.receive }, reply]
end

# ---- 运行 ----

puts "Ruby #{RUBY_DESCRIPTION}"
puts "Troupe #{Troupe::VERSION} 并发基准（内存 store、无传输；每场景先预热再计时）\n\n"

troupe = Troupe.form(
  actors: [PingActor, IoStrictActor, IoImprovActor],
  prop_store: :memory, cue_store: :memory, transport: false
)

# ============ P1. 调用管线开销 ============

puts "── P1. 调用管线开销（1 次同步往返的成本）──"

Echo = Object.new
def Echo.ping(i) = i

warm = troupe.cast(PingActor, "p1")
warm.ping(0)
warm.incr

N_DIRECT = 200_000
N_FIBER  = 200_000
N_THREAD = 20_000
N_TROUPE = 10_000

rows = []
rows << ["直接方法调用", N_DIRECT, measure { N_DIRECT.times { |i| Echo.ping(i) } }]

pong = Fiber.new { |x| loop { x = Fiber.yield(x) } }
rows << ["Fiber ping-pong", N_FIBER,
         measure { N_FIBER.times { |i| pong.resume(i) } }]

box = Queue.new
t_actor = Thread.new do
  loop do
    msg = box.pop
    break if msg.equal?(:stop)

    msg[1] << msg[0]
  end
end
rows << ["原生 Thread ping-pong", N_THREAD,
         measure do
           N_THREAD.times do |i|
             reply = Queue.new
             box << [i, reply]
             reply.pop
           end
         end]
box << :stop
t_actor.join

rows << ["Troupe 演员 ping", N_TROUPE, measure { N_TROUPE.times { |i| warm.ping(i) } }]
rows << ["Troupe 演员 incr（save_props）", 2_000, measure { 2_000.times { warm.incr } }]

N_RACTOR = 2_000
r_reply = Ractor::Port.new
r_actor = Ractor.new(r_reply) do |rp|
  my_in = Ractor::Port.new
  rp.send(my_in)
  loop do
    msg = my_in.receive
    break if msg == :stop
    rp.send(msg)
  end
end
r_port = r_reply.receive # 握手
rows << ["Ractor ping-pong", N_RACTOR,
         measure { N_RACTOR.times { |i| r_port.send(i); r_reply.receive } }]
r_port.send(:stop)
r_actor.join

rows.each do |name, n, m|
  printf("  %-32s %10.0f ops/s   CPU %5.1f%%   allocs/op %5.1f   RSS %+6.0fKB   峰值线程 %3d\n",
         name, n / m[:wall], m[:cpu] / m[:wall] * 100, m[:allocs].to_f / n, m[:rss], m[:peak_threads])
end
puts ""

# ============ P2. 单演员串行性 ============

puts "── P2. 单演员串行性（ping 为纯内存往返）──"
a = troupe.cast(PingActor, "p2")
201.times { |i| a.ping(i) } # 预热：激活 + 调度线程创建

wall_a1, lats_a1 = run_load([[a, 5_000]]) { |ag| ag.ping(1) }
ops_a1 = 5_000 / wall_a1
printf("  P2a  1 演员 × 1 客户端 × 5000   %9.0f ops/s   mean %7.3fms  p50 %7.3fms  p99 %7.3fms\n",
       ops_a1, lats_a1.sum / lats_a1.length, pct(lats_a1, 50), pct(lats_a1, 99))

wall_a2, lats_a2 = run_load(Array.new(8) { [a, 625] }) { |ag| ag.ping(1) }
ops_a2 = 5_000 / wall_a2
printf("  P2b  1 演员 × 8 客户端 × 625    %9.0f ops/s   mean %7.3fms  p50 %7.3fms  p99 %7.3fms\n",
       ops_a2, lats_a2.sum / lats_a2.length, pct(lats_a2, 50), pct(lats_a2, 99))
mean_a1 = lats_a1.sum / lats_a1.length
mean_a2 = lats_a2.sum / lats_a2.length
printf("  → 吞吐比 P2b/P2a = %.2f（远小于客户端数 8），平均延迟比 = %.1f（≈按并发数线性排队）\n\n",
       ops_a2 / ops_a1, mean_a2 / mean_a1)

# ============ P3. I/O 重叠横向对比 ============

CALLS = 320
IO_MS = 10

puts "── P3. I/O 重叠横向对比（io = sleep #{IO_MS}ms × #{CALLS} 次；Windows 实际 ≈15.6ms/次）──"
printf("  %-28s %9s %9s %8s %12s %10s %8s\n",
       "机制", "ops/s", "wall(s)", "CPU%", "allocs/次", "RSS ΔKB", "峰值线程")

s_actor = troupe.cast(IoStrictActor, "p3-strict")
s_actor.io_work(1)
m = measure { CALLS.times { s_actor.io_work(IO_MS) } }
printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
       "Troupe strict（C=1 基线）", CALLS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
       m[:allocs].to_f / CALLS, m[:rss], m[:peak_threads])

m_actor = troupe.cast(IoImprovActor, "p3-improv")
m_actor.io_work(1)
sched = SleepScheduler.new

{ 16 => 20, 80 => 4, 320 => 1 }.each do |c, per|
  # Troupe improv：C 条客户端线程同步调用，标注调用各自在独立线程交错（DESIGN §5.4）
  m = measure do
    ths = Array.new(c) { Thread.new { per.times { m_actor.io_work(IO_MS) } } }
    ths.each(&:join)
  end
  printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
         "Troupe improv (C=#{c})", CALLS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
         m[:allocs].to_f / CALLS, m[:rss], m[:peak_threads])

  # 原生 Thread 池：C 条 worker 共享任务队列
  m = measure do
    jobs = Queue.new
    CALLS.times { jobs << IO_MS }
    workers = Array.new(c) do
      Thread.new do
        while (ms = jobs.pop(true) rescue nil)
          sleep(ms / 1000.0)
        end
      end
    end
    workers.each(&:join)
  end
  printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
         "原生 Thread 池 (C=#{c})", CALLS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
         m[:allocs].to_f / CALLS, m[:rss], m[:peak_threads])

  # Fiber Scheduler：单线程事件循环
  m = measure do
    Fiber.set_scheduler(sched)
    fiber_overlap(CALLS, c, IO_MS, sched)
    Fiber.set_scheduler(nil)
  end
  printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
         "Fiber 事件循环 (C=#{c})", CALLS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
         m[:allocs].to_f / CALLS, m[:rss], m[:peak_threads])

  # Ractor 池：C 个 Ractor worker，任务经 Port 分发（创建成本计入测量）
  m = measure do
    workers, wports, reply3 = ractor_pool(c)
    per = CALLS / c
    wports.each { |wp| per.times { wp.send(["io", IO_MS]) } }
    CALLS.times { reply3.receive }
    wports.each { |wp| wp.send(:stop) }
    workers.each(&:join)
  end
  printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
         "Ractor 池 (C=#{c})", CALLS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
         m[:allocs].to_f / CALLS, m[:rss], m[:peak_threads])
end
puts ""

# ============ P4. CPU 密集横向对比（Ractor 的主场）============

CPU_TASKS = 16
CPU_C = [Etc.nprocessors, 8].min
CPU_ITERS = begin # 就近标定：贴近测量时机，减少环境漂移影响
  t0 = MONO.call
  CpuTask.run(50_000)
  (50_000 * 0.04 / (MONO.call - t0)).round
end
puts "  （单任务标定：#{CPU_ITERS} 次迭代 ≈ 40ms）"

puts "── P4. CPU 密集横向对比（零分配整数混合 × #{CPU_TASKS} 任务，单任务 ~40ms；#{Etc.nprocessors} 逻辑核）──"
printf("  %-28s %9s %9s %8s %12s %10s %8s\n",
       "机制", "ops/s", "wall(s)", "CPU%", "allocs/次", "RSS ΔKB", "峰值线程")

m = measure { CPU_TASKS.times { CpuTask.run(CPU_ITERS) } }
printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
       "串行（主线程）", CPU_TASKS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
       m[:allocs].to_f / CPU_TASKS, m[:rss], m[:peak_threads])

m = measure do
  jobs = Queue.new
  CPU_TASKS.times { jobs << CPU_ITERS }
  ths = Array.new(CPU_C) do
    Thread.new do
      while (n = jobs.pop(true) rescue nil)
        CpuTask.run(n)
      end
    end
  end
  ths.each(&:join)
end
printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
       "原生 Thread 池 (C=#{CPU_C})", CPU_TASKS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
       m[:allocs].to_f / CPU_TASKS, m[:rss], m[:peak_threads])

m = measure do
  workers, wports, reply4 = ractor_pool(CPU_C)
  per = CPU_TASKS / CPU_C
  wports.each { |wp| per.times { wp.send(["cpu", CPU_ITERS]) } }
  CPU_TASKS.times { reply4.receive }
  wports.each { |wp| wp.send(:stop) }
  workers.each(&:join)
end
printf("  %-28s %9.0f %9.2f %8.1f %12.1f %10.0f %8d\n",
       "Ractor 池 (C=#{CPU_C})", CPU_TASKS / m[:wall], m[:wall], m[:cpu] / m[:wall] * 100,
       m[:allocs].to_f / CPU_TASKS, m[:rss], m[:peak_threads])
puts ""

# ============ P5. 并发单元驻留成本 ============

UNITS = 100
puts "── P5. 并发单元驻留成本（#{UNITS} 个单元挂起待命；RSS/线程数为净增量）──"

# Troupe：激活并保持在场（含调度线程 + Props 存储 + CallBoard）
s1 = snap!
Array.new(UNITS) { |i| troupe.cast(PingActor, "p4-#{i}").ping(0) }
troupe_allocs = GC.stat(:total_allocated_objects) - s1.allocs
troupe_rss = Res.rss_kb - s1.rss
troupe_threads = Thread.list.size - s1.threads

# 原生 Thread：各阻塞在私有 Queue 上
s2 = snap!
qs = Array.new(UNITS) { Queue.new }
t_threads = qs.map { |q| Thread.new { q.pop } }
thread_allocs = GC.stat(:total_allocated_objects) - s2.allocs
thread_rss = Res.rss_kb - s2.rss
thread_threads = Thread.list.size - s2.threads

# Fiber：挂起在 Fiber.yield 上
s3 = snap!
parked = Array.new(UNITS) { Fiber.new { Fiber.yield } }
parked.each(&:resume)
fiber_allocs = GC.stat(:total_allocated_objects) - s3.allocs
fiber_rss = Res.rss_kb - s3.rss
fiber_threads = Thread.list.size - s3.threads

# Ractor：各阻塞在私有 Port#receive 上（握手回传收件口）
s4 = snap!
r_reply5 = Ractor::Port.new
r_parked = Array.new(UNITS) do
  Ractor.new(r_reply5) do |rp|
    my_in = Ractor::Port.new
    rp.send(my_in)
    loop do
      msg = my_in.receive
      break if msg == :stop
      rp.send(msg)
    end
  end
end
r_pports = Array.new(UNITS) { r_reply5.receive }
ractor_allocs = GC.stat(:total_allocated_objects) - s4.allocs
ractor_rss = Res.rss_kb - s4.rss
ractor_ractors = Ractor.count - s4.ractors

printf("  %-24s allocs/单元 %6d   RSS/单元 %6.1f KB   净增线程 %4d\n",
       "Troupe 演员（在场）", troupe_allocs / UNITS, troupe_rss / UNITS, troupe_threads)
printf("  %-24s allocs/单元 %6d   RSS/单元 %6.1f KB   净增线程 %4d\n",
       "原生 Thread（阻塞）", thread_allocs / UNITS, thread_rss / UNITS, thread_threads)
printf("  %-24s allocs/单元 %6d   RSS/单元 %6.1f KB   净增线程 %4d\n",
       "Fiber（挂起）", fiber_allocs / UNITS, fiber_rss / UNITS, fiber_threads)
printf("  %-24s allocs/单元 %6d   RSS/单元 %6.1f KB   净增 Ractor %3d\n",
       "Ractor（阻塞收件）", ractor_allocs / UNITS, ractor_rss / UNITS, ractor_ractors)

t_threads.each(&:kill)
r_pports.each { |p| p.send(:stop) }
r_parked.each(&:join)

puts <<~NOTES

  解读：
  * P1：Fiber 切换（同线程，亚 μs）≪ 原生 Thread ping-pong ≈ Ractor ping-pong
    （两次线程切换，跨 Ractor 消息还要深拷贝）≪
    Troupe 调用（两次切换 + Call/CallBoard/Codec/trace 全套管道）；
    save_props 的增量即持久化复制 + CAS 提交成本。allocs/op 反映各机制的分配压力。
  * P2：演员内严格串行——多客户端只是排队（延迟按并发数线性上升，吞吐不增），
    这是状态正确性来源，不是可扩展性来源。
  * P3：各机制都能重叠 I/O 等待，但资源画像不同——
    improv 每个在飞调用一条标注线程 + 一条同步客户端线程（峰值线程最高、CPU churn 大），
    且 C=320 时吞吐回落（647 条线程的创建/调度开销反噬）；
    Thread 池固定 C 条线程，规模温和；Fiber 事件循环单线程（~7 条）、allocs 最少；
    Ractor 池 C 小时与 Thread 池相当，C 大时创建/握手成本显现（C=320 要建 320 个 Ractor）。
    strict 则完全串行，只能靠"多演员"横向分流。
  * P4：CPU 密集是 Ractor 的主场——Thread 池被 GVL 封顶（与串行持平甚至更慢），
    Ractor 池按核数近似线性加速（CPU% 可达数百）。注意任务必须零分配：
    分配型任务在 Ractor 下会争抢全局 GC 锁（本基准早期版本用素数扫描时，
    8 Ractor 反而比串行慢 20 倍以上）。代价还包括消息深拷贝与独立堆。
    Fiber 与 Thread 一样无法并行 CPU。
  * P5：每个驻留单元的内存量级 = Thread ≈ Troupe 演员（栈 + 状态 + 队列）> Ractor > Fiber；
    万级并发单元应考虑 Fiber 化运行时或分片多进程/Ractor。
  * GVL：MRI 下 CPU 密集方法只有 Ractor 能真并行（跨进程分片/集群亦可）；
    I/O 重叠则 Thread 池 / Fiber / Ractor 都能做，Fiber 的资源成本最低。
NOTES

troupe.drain_all
troupe.shutdown!
