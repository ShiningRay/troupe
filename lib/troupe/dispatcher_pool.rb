# frozen_string_literal: true

require_relative "util"

module Troupe
  # 共享调度池（dispatcher: :shared 模式）。
  #
  # 设计借鉴 concurrent-ruby 的 FixedThreadPool / CachedThreadPool（worker 复用、
  # 就绪队列、后备任务），以纯 stdlib（Queue + Thread）实现——保持"运行时零 gem 依赖"。
  #
  # 架构：M 条调度线程多路复用 K 个 Cell 的 CallBoard，替代"每 Cell 一条调度线程"。
  # 这把 troupejs 事件循环（Node 单线程跑全部 Actor）的调度模型映射到线程池上：
  #   * 激活不再付 Thread.new 成本（实测 ~454µs/线程，是 thread_per_cell 模式
  #     激活吞吐的硬上限）；常驻 Actor 不再各持一条线程栈。
  #
  # 严格串行语义由 Cell 的 enqueued 令牌保证：同一 Cell 同时至多在一个调度线程上
  # 处理一个批次（offer → 置令牌入队 → 批次处理完 → 归还令牌；归还与置位都在
  # Cell#lock 内完成，不会丢唤醒）。
  #
  # 与 :thread_per_cell 的显式语义差异（选 :shared 即接受）：
  #   * 一个阻塞 Turn 占住一条共享调度线程，其余 M-1 条继续服务其它 Cell
  #     （不再有"阻塞互不影响"的完全隔离；与 Node 事件循环的取舍一致）；
  #   * 强杀挂起 Turn（Cell#kill!）不可用——不能为单个 Cell 杀掉共享线程；
  #     停机宽限期内未排空的 Cell 记录错误日志后放弃；
  #   * Intermission 钝化由后台 sweeper 周期扫描触发（默认 1s 粒度，秒级精度）。
  class SharedDispatcherPool
    def initialize(threads:, sweep_interval: 1.0)
      @ready = Queue.new
      @stopped = false
      @sweep_interval = sweep_interval
      @sweeper = nil
      @threads = Array.new([threads, 1].max) do
        t = Thread.new { worker_loop }
        begin
          t.name = "troupe-shared-dispatcher"
        rescue StandardError
          nil
        end
        t
      end
    end

    # Cell 入队（offer / request_drain! 自带 poke / sweeper 用）。
    # 幂等性由 Cell 侧 enqueued 令牌保证，这里只负责投递。
    def push(cell)
      @ready << cell
      nil
    end

    # 启动 intermission 扫描线程：周期性对"空闲超过 Intermission"的 Cell
    # 触发 request_drain!(:intermission)（Cell 侧会自动入队交由调度线程排空）。
    def start_sweeper(stage_manager)
      @sweeper = Thread.new do
        loop do
          sleep @sweep_interval
          stage_manager.sweep_intermissions!
        rescue StandardError => e
          Log.error("shared dispatcher sweeper 异常：#{e.class}: #{e.message}")
        end
      end
      begin
        @sweeper.name = "troupe-shared-sweeper"
      rescue StandardError
        nil
      end
      nil
    end

    # 停机：等所有 worker 退出当前批次后结束（StageManager.shutdown 已先排空 Cell）
    def stop!
      return if @stopped

      @stopped = true
      @threads.size.times { @ready << :stop }
      @threads.each(&:join)
      @sweeper&.kill
      nil
    end

    private

    def worker_loop
      loop do
        item = @ready.pop
        break if item.equal?(:stop)

        item.run_shared_batch(self)
      end
    rescue StandardError => e
      # 兜底：run_shared_batch 内部已救援业务异常；这里防御调度器自身 bug，不让线程消失
      Log.error("shared dispatcher worker 异常重启：#{e.class}: #{e.message} #{e.backtrace&.first}")
      retry
    end
  end
end
