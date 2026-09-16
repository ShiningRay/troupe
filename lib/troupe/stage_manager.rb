# frozen_string_literal: true

require_relative "call"
require_relative "codec"
require_relative "errors"
require_relative "util"

module Troupe
  # Actor 的框架侧上下文：save_props（CAS 提交）、Cue、提醒、互调（DESIGN §7.1/§10.1）
  class ActorContext
    attr_reader :cell, :troupe, :props

    def initialize(cell, props)
      @cell = cell
      @troupe = cell.troupe
      @props = props
    end

    def stage_name
      @cell.stage_name
    end

    def fencing_token
      @cell.fencing_token
    end

    # 持久成功（DESIGN §7.3）：CAS 提交（业务变更）成功后才返回。
    # 返回新 revision（可序列化标量——用户方法常以 save_props 结尾，返回值会过边界）。
    # 失败/冲突 → 默认实例失效（poison），下次调用从最后已提交快照继续。
    def save_props
      stored = @troupe.prop_store.write(
        @cell.namespace, @cell.role_id, @cell.stage_name,
        Codec.copy(@props),
        expected_revision: @cell.revision,
        schema_version: @cell.role_class.schema_version,
        fencing_token: @cell.fencing_token
      )
      @cell.revision = stored.revision
      stored.revision
    rescue ConflictError
      @cell.poison!
      raise
    end

    def register_cue(name, every, blk)
      @cell.register_cue(name, every, blk)
    end

    def cancel_cue(name)
      @cell.cancel_cue(name)
    end

    def schedule_reminder(name, spec, payload)
      cell.schedule_reminder(name, spec, payload)
    end

    def cancel_reminder(name)
      cell.cancel_reminder(name)
    end

    def cast(klass_or_role_id, stage_name, timeout: nil)
      @troupe.cast(klass_or_role_id, stage_name, timeout: timeout)
    end
  end

  # 舞台监督（StageManager，DESIGN §5）：每 (role, stageName) 一个 Cell；
  # Cell 内默认严格串行——上一 Turn settle 前不取下一 Call。
  class StageManager
    attr_reader :troupe

    def initialize(troupe)
      @troupe = troupe
      @cells = {}
      @lock = Mutex.new
      @changed = ConditionVariable.new
      @budget = ByteBudget.new(troupe.config.queue_bytes_limit)
    end

    def config
      @troupe.config
    end

    def repertoire
      @troupe.repertoire
    end

    def queue_budget
      @budget
    end

    # 本地派发入口：Agent / 提醒 / Director invoke / 转发落地（DESIGN §5.1 执行模型）
    def deliver(call)
      raise CallRejectedError, "Stage 正在停机：拒绝新 Call（DESIGN §8.2）" if @troupe.stopping? && !call.internal?

      klass = repertoire[call.role_id]
      validate_call!(klass, call)
      if call.source == :local && !config.local_call_by_reference
        # 本地调用走同一编解码/复制边界（DESIGN §6.1）
        call.args = Codec.copy(call.args)
      end
      resolve_cell(klass, call)
      # 执行结果与指标由 run_turn / settle_expired! 统一记录
      call.box.wait!(call.deadline_ms)
    rescue StandardError => e
      # 执行期结果已由 run_turn settle 并计数；这里只补记执行前的拒绝
      unless call.box.settled?
        kind = e.is_a?(TroupeError) ? e.kind : :business
        dur = Util.mono - (t0 ||= Util.mono)
        @troupe.metrics.observe(call.role_id, kind, dur)
        @troupe.trace.emit(
          "at" => Util.now_ms, "stage" => @troupe.advertise, "from" => (call.from_stage || call.source.to_s),
          "role" => call.role_id, "stageName" => call.stage_name, "method" => call.method.to_s,
          "durationMs" => (dur * 1000).round(3), "outcome" => kind.to_s, "callId" => call.call_id
        )
      end
      raise
    end

    # 信任边界（DESIGN §6.1）：方法必须在角色白名单内；生命周期钩子与基类成员
    # 不可经普通 RPC 调用；internal 调用只能由框架在进程内构造。
    def validate_call!(klass, call)
      raise CallRejectedError, "参数必须是数组" unless call.args.is_a?(Array)
      if !call.internal? && call.method.to_s.start_with?("__")
        raise UnknownMethodError, "方法 #{call.method} 不可调用：双下划线保留给框架内部"
      end
      unless call.internal? || klass.valid_rpc?(call.method)
        raise UnknownMethodError,
              "方法 #{call.method} 不在角色 #{klass.role_id} 的白名单内（生命周期钩子、基类成员、" \
              "未定义方法均不可经 RPC 调用，DESIGN §6.1）"
      end

      return if call.internal? || call.block?

      arity = klass.instance_method(call.method).arity
      n = call.args.size
      required = arity >= 0 ? arity : -arity - 1
      ok = arity >= 0 ? n == arity : n >= required
      unless ok
        raise CallRejectedError, "参数个数不符：#{klass.role_id}.#{call.method} 期望 #{arity}，收到 #{n}"
      end
    end

    def resolve_cell(klass, call)
      loop do
        check_activation_limit
        key = call.key
        cell = @lock.synchronize { @cells[key] ||= Cell.new(self, klass, call.namespace, call.role_id, call.stage_name) }
        case cell.offer(call)
        when :accepted then return cell
          # :draining / :invalid —— 等待旧实例从在场表消失后重新解析（重新激活，DESIGN §5.2）
        end
        wait_cell_removed(cell, call)
      end
    end

    def check_activation_limit
      @lock.synchronize do
        if @cells.size >= config.activation_limit
          raise BackpressureError, "在场激活数超限（#{@cells.size} >= #{config.activation_limit}）：过载显式拒绝（DESIGN §5.3）"
        end
      end
    end

    def wait_cell_removed(cell, call)
      deadline = call.deadline_ms
      key = call.key
      @lock.synchronize do
        while @cells[key].equal?(cell)
          if deadline && deadline <= Util.now_ms
            raise CallTimeoutError, "等待前一个实例排空超时：结果未知（DESIGN §5.2：排空期间新请求等待）"
          end
          remaining = deadline ? (deadline - Util.now_ms) / 1000.0 : 1.0
          @changed.wait(@lock, remaining)
        end
      end
    end

    def remove_cell(cell)
      @lock.synchronize do
        @cells.delete_if { |_k, c| c.equal?(cell) }
        @changed.broadcast
      end
      nil
    end

    def cell_count
      @lock.synchronize { @cells.size }
    end

    def cells_snapshot
      @lock.synchronize { @cells.values.dup }
    end

    def queued_bytes
      @budget.used
    end

    # 管理下场（Director `off`，DESIGN §11.1）：排空 + offStage + saveProps
    def admin_off(role_id, stage_name, timeout: 10.0)
      cell = @lock.synchronize { @cells[[config.namespace, role_id, stage_name]] }
      return false unless cell

      cell.request_drain!(:admin)
      cell.wait_drained!(timeout)
      true
    end

    def inspect_cell(role_id, stage_name)
      cell = @lock.synchronize { @cells[[config.namespace, role_id, stage_name]] }
      return nil unless cell

      cell.detail
    end

    def actors_info
      cells_snapshot.map(&:info)
    end

    # quiesce（DESIGN §5.2/§9.6）：等待所有运行中请求与框架回调结束
    def quiesce(timeout_s)
      deadline = Util.mono + timeout_s
      loop do
        busy = cells_snapshot.any? { |c| !c.idle? }
        return true unless busy
        return false if Util.mono >= deadline

        sleep 0.005
      end
    end

    # 优雅停机（DESIGN §8.2）：拒新 Call 已由 troupe.stopping? 保证；
    # 等待存量 Call settle → 全员 offStage+saveProps → 移除
    def shutdown(grace_s)
      cells = cells_snapshot
      return if cells.empty?

      deadline = Util.mono + grace_s
      cells.each { |c| c.request_drain!(:shutdown) }
      cells.each do |c|
        remaining = deadline - Util.mono
        c.wait_drained!(remaining.positive? ? remaining : 0.001)
      end
      cells.each do |c|
        next unless c.alive?

        Log.error("#{c.label} 未能宽限期内排空，强制终止（用户任务挂起：恢复靠进程隔离，DESIGN §5.1）")
        c.kill!
      end
    end

    # 排空全部在场演员但不关停 Stage（测试/演示：offStage + saveProps 验证）
    def drain_all_cells(timeout_s)
      cells = cells_snapshot
      cells.each { |c| c.request_drain!(:admin) }
      deadline = Util.mono + timeout_s
      cells.each do |c|
        remaining = deadline - Util.mono
        c.wait_drained!(remaining.positive? ? remaining : 0.001)
      end
      cells
    end
  end

  # 一个 (namespace, role, stageName) 的在场单元：
  # 生命周期状态机（未激活/激活中/运行中/排空中/失效，DESIGN §5.2）+ CallBoard + 串行通道。
  # Ruby 适配：Node 的"事件循环 + Promise settle"映射为"每 Cell 一条调度线程"，
  # 严格串行 = 调度线程逐条执行；响应期限与执行占用分离 = 等待超时不中断执行线程。
  class Cell
    attr_reader :troupe, :role_class, :namespace, :role_id, :stage_name, :state
    attr_accessor :revision, :fencing_token

    def initialize(manager, role_class, namespace, role_id, stage_name)
      @manager = manager
      @troupe = manager.troupe
      @role_class = role_class
      @namespace = namespace
      @role_id = role_id
      @stage_name = stage_name

      @state = :inactive
      @finished = false
      @lock = Mutex.new
      @state_cv = ConditionVariable.new
      @turn_lock = Mutex.new
      @turn_cv = ConditionVariable.new
      @in_flight = 0
      @annotated = 0
      @board = CallBoard.new(limit: role_class.call_board_limit, budget: manager.queue_budget)
      @intermission = Util.parse_duration(
        role_class.intermission || @troupe.config.intermission, "intermission"
      )
      @thread = nil
      @actor = nil
      @revision = 0
      @fencing_token = 0
      @born_at = Util.now_ms
      @last_activity = Util.mono
      @stop_requested = false
      @drain_reason = nil
      @poisoned = false
      @cues = {}
      @cue_lock = Mutex.new
    end

    def label
      "#{@role_id}/#{@stage_name}"
    end

    # ---- 调用进入 ----

    # 返回 :accepted；:draining/:invalid 交由 manager 重试。
    # BoardFullError / BackpressureError 直接抛出（过载显式拒绝）。
    def offer(call)
      @lock.synchronize do
        return :draining if @state == :draining
        return :invalid if @state == :invalid

        @board.push!(call)
        spawn_dispatcher
        :accepted
      end
    end

    def spawn_dispatcher
      return if @thread&.alive?

      @thread = Thread.new { run_loop }
      begin
        @thread.name = "troupe-#{@role_id}-#{@stage_name}"
      rescue StandardError
        nil
      end
    end

    def request_drain!(reason)
      @lock.synchronize do
        @stop_requested = true
        @drain_reason ||= reason
      end
      @board.wake!
    end

    def wait_drained!(timeout)
      deadline = Util.mono + timeout
      @lock.synchronize do
        until @finished
          remaining = deadline - Util.mono
          return false if remaining <= 0

          @state_cv.wait(@lock, remaining)
        end
      end
      true
    end

    def alive?
      @thread&.alive? ? true : false
    end

    def kill!
      @thread&.kill
    end

    def poison!
      @poisoned = true
    end

    def depth
      @board.depth
    end

    def idle?
      state = @lock.synchronize { @state }
      return true if state == :inactive

      in_flight = @turn_lock.synchronize { @in_flight }
      state == :running && @board.depth.zero? && in_flight.zero?
    end

    def intermission_remaining_s
      [@intermission - (Util.mono - @last_activity), 0.0].max
    end

    def info
      @lock.synchronize do
        {
          "role" => @role_id, "stageName" => @stage_name, "state" => @state.to_s,
          "bornAt" => @born_at, "lastActivityMsAgo" => ((Util.mono - @last_activity) * 1000).round,
          "callBoardDepth" => @board.depth, "revision" => @revision,
          "fencingToken" => @fencing_token, "intermissionIn" => intermission_remaining_s.round(2)
        }
      end
    end

    def detail
      info.merge("props" => props_snapshot, "cues" => @cue_lock.synchronize { @cues.keys })
    end

    # Props 快照（Director inspect）：尽力而为，读取期间遇并发修改则重试
    def props_snapshot
      actor = @actor
      return nil unless actor

      3.times do
        begin
          return Codec.copy(actor.props)
        rescue StandardError
          sleep 0.005
        end
      end
      nil
    end

    # ---- 调度线程（严格串行的执行通道） ----

    def run_loop
      loop do
        break if @stop_requested

        idle = @intermission - (Util.mono - @last_activity)
        call = @board.pop(timeout: idle.positive? ? idle : 0.001)
        if call.nil?
          if @stop_requested
            drain!(@drain_reason)
            break
          end
          # wake 唤醒但 Intermission 未到期 → 继续等待
          next unless idle_due?

          drain!(:intermission)
          break
        end

        # 排队过期不执行：未开始、无副作用，可安全拒绝（DESIGN §5.1）
        next if settle_expired!(call)

        @last_activity = Util.mono
        begin
          activate! unless running?
          execute_turn(call)
        rescue StandardError => e
          # 当前 Call 先 settle（不悬挂调用方），再交给外层失效处理
          call.box.settle_error(e) unless call.box.settled?
          raise
        end
        if @stop_requested
          drain!(@drain_reason)
          break
        end
        if @poisoned
          # 保存失败/冲突：实例失效，不继续使用失效或未提交状态（DESIGN §7.3）
          fail_all_queued!(InvalidActorStateError.new("#{label} Props 提交失败，实例已失效：下次调用从最后已提交快照继续"))
          invalidate!
          break
        end
      end
    rescue StandardError => e
      Log.error("#{label} 调度线程异常退出：#{e.class}: #{e.message} #{e.backtrace&.first}")
      begin
        fail_all_queued!(InvalidActorStateError.new("#{label} 调度器异常退出：#{e.message}"))
        invalidate!
      rescue StandardError
        nil
      end
    ensure
      @manager.remove_cell(self)
      @lock.synchronize do
        @finished = true
        @state_cv.broadcast
      end
    end

    def finished?
      @lock.synchronize { @finished ? true : false }
    end

    def idle_due?
      @board.depth.zero? && (Util.mono - @last_activity) >= @intermission
    end

    def settle_expired!(call)
      return false unless call.expired?

      call.box.settle_error(CallTimeoutError.new("排队已过期：未开始执行、无副作用，已拒绝（DESIGN §5.1）"))
      @troupe.metrics.observe(@role_id, :rejected, 0.0)
      true
    end

    def running?
      @lock.synchronize { @state } == :running
    end

    # ---- 激活（single-flight：队列语义天然保证只激活一次，DESIGN §5.2） ----

    def activate!
      @lock.synchronize do
        return if @state == :running

        @state = :activating
      end
      @troupe.events.publish(:activating, role_id: @role_id, stage_name: @stage_name)
      klass = @role_class
      store = @troupe.prop_store

      acquire_ownership! if ownership_needed?

      stored = store.read(@namespace, @role_id, @stage_name)
      if stored
        props = Codec.copy(stored.props) # 已提交快照（同一编解码边界）
        if stored.schema_version < klass.schema_version
          props = run_migration(klass, store, props, stored)
        end
      else
        props = klass.build_initial_props
        begin
          stored = store.create(@namespace, @role_id, @stage_name, Codec.copy(props),
                                schema_version: klass.schema_version, fencing_token: @fencing_token)
        rescue ConflictError
          # 创建竞态（跨 Stage 抢激活）：以已存在记录为准
          stored = store.read(@namespace, @role_id, @stage_name) ||
                   raise(ActivationError, "#{label} Props 创建竞态且读取失败")
          props = Codec.copy(stored.props)
        end
      end

      @context = ActorContext.new(self, props)
      @actor = klass.new(@context)
      @revision = stored.revision
      begin
        @actor.validate_props!(@actor.props)
        @actor.on_stage
      rescue TroupeError
        raise
      rescue StandardError => e
        raise ActivationError, "#{label} 激活失败（onStage/validateProps）：#{e.class}: #{e.message}"
      end
      @lock.synchronize do
        @state = :running
        @last_activity = Util.mono
        @state_cv.broadcast
      end
      @troupe.metrics.note_activation(@role_id)
      @troupe.events.publish(:activated, role_id: @role_id, stage_name: @stage_name)
    end

    def ownership_needed?
      @troupe.prop_store.ownership_enabled? && @troupe.config.ownership
    end

    # 激活前置：CAS 取得所有权（新 epoch > 旧）才登台（DESIGN §6.5）
    def acquire_ownership!
      store = @troupe.prop_store
      lease_ms = (Util.parse_duration(@troupe.config.ownership_lease, "租约") * 1000).to_i
      timeout_s = Util.parse_duration(@troupe.config.ownership_acquire_timeout, "所有权等待")
      deadline = Util.now_ms + (timeout_s * 1000).to_i
      loop do
        rec = store.acquire_ownership(@namespace, @role_id, @stage_name,
                                      owner: @troupe.owner_id, lease_ms: lease_ms)
        if rec
          @fencing_token = rec.epoch
          return
        end
        raise OwnershipError, "#{label} 等待所有权超时：租约正由其他 Stage 持有（DESIGN §6.5）" if Util.now_ms >= deadline

        sleep 0.05
      end
    end

    # schemaVersion 驱动迁移（DESIGN §7.4）：迁移后 CAS 提交；失败明确报错、不以半迁移状态服务
    def run_migration(klass, store, props, stored)
      temp = klass.new(ActorContext.new(self, props))
      begin
        migrated = temp.migrate_props(props, stored.schema_version)
      rescue MigrationError
        raise
      rescue StandardError => e
        raise MigrationError, "#{label} Props 迁移失败（#{stored.schema_version} → #{klass.schema_version}）：#{e.class}: #{e.message}"
      end
      migrated = Codec.copy(migrated)
      begin
        store.write(@namespace, @role_id, @stage_name, migrated,
                    expected_revision: stored.revision, schema_version: klass.schema_version,
                    fencing_token: @fencing_token)
      rescue ConflictError
        again = store.read(@namespace, @role_id, @stage_name)
        if again && again.schema_version >= klass.schema_version
          return Codec.copy(again.props) # 并发迁移：以已提交版本为准
        end
        raise MigrationError, "#{label} Props 迁移提交冲突：#{role_id} schema_version=#{stored.schema_version}"
      end
      migrated
    end

    # ---- Turn 执行（严格串行 + 交错矩阵，DESIGN §5.1/§5.4） ----

    def execute_turn(call)
      kind = call.internal? || call.block? ? :strict : @role_class.call_kind(call.method)
      if kind == :annotated
        # 单调度线程保证写饥饿防护：strict 被取出等待期间，不会启动新 annotated
        spawn_annotated(call)
      else
        wait_no_annotated!(call)
        run_turn(call, annotated: false)
      end
    end

    # strict 仅在飞 annotated 为 0 时启动；等待期间 Call 过期 → 排队过期语义
    def wait_no_annotated!(call)
      @turn_lock.synchronize do
        while @annotated.positive?
          if call.expired?
            call.box.settle_error(CallTimeoutError.new("等待交错在飞请求结束超时：结果未知（DESIGN §5.4）"))
            @troupe.metrics.observe(@role_id, :rejected, 0.0)
            return
          end
          @turn_cv.wait(@turn_lock, 0.02)
        end
      end
    end

    def spawn_annotated(call)
      @turn_lock.synchronize { @annotated += 1 }
      Thread.new do
        begin
          Thread.current.name = "troupe-#{@role_id}-#{@stage_name}-annotated"
        rescue StandardError
          nil
        end
        run_turn(call, annotated: true)
      end
    end

    def run_turn(call, annotated:)
      @turn_lock.synchronize { @in_flight += 1 }
      t0 = Util.mono
      err = nil
      result = nil
      begin
        result = call.block? ? call.block_call(@actor) : @actor.public_send(call.method, *call.args)
      rescue StandardError => e
        err = e
        # CAS 冲突 = 状态可能已失效：不继续使用（DESIGN §7.3）
        @poisoned = true if e.is_a?(ConflictError)
      ensure
        dur = Util.mono - t0
        @last_activity = Util.mono
        @turn_lock.synchronize do
          @annotated -= 1 if annotated
          @in_flight -= 1
          @turn_cv.broadcast
        end
      end

      if err
        call.box.settle_error(err)
        outcome = err.is_a?(TroupeError) ? err.kind : :business
      else
        call.box.settle_ok(copy_result(call, result))
        outcome = :ok
      end
      @troupe.metrics.observe(@role_id, outcome, dur)
      @troupe.trace.emit(
        "at" => Util.now_ms, "stage" => @troupe.advertise, "from" => (call.from_stage || call.source.to_s),
        "role" => @role_id, "stageName" => @stage_name, "method" => (call.block? ? "cue:#{call.method}" : call.method.to_s),
        "durationMs" => (dur * 1000).round(3), "outcome" => outcome.to_s, "callId" => call.call_id
      )
    end

    def copy_result(call, result)
      return result if @troupe.config.local_call_by_reference && call.source == :local

      Codec.copy(result)
    end

    # ---- 排空 / 失效 ----

    # 排空（DESIGN §5.1）：等在飞 Turn 结束 → offStage → saveProps → 释放 → 移除 →
    # 排空期间到达的排队请求重新派发（等待排空完成后重新激活）
    def drain!(reason)
      @lock.synchronize { @state = :draining }
      cancel_cues
      queued = @board.drain_all!
      wait_turns_settle!
      Log.debug("#{label} 下场（reason=#{reason || @drain_reason}）")
      if @actor
        begin
          @actor.off_stage
        rescue StandardError => e
          Log.warn("#{label} offStage 钩子抛错：#{e.class}: #{e.message} → 实例失效")
          invalidate!
          re_dispatch(queued)
          return
        end
        begin
          @context.save_props
        rescue TroupeError => e
          # 排空保存冲突（旧实例）：不得无条件重写，失效让位给新所有者（DESIGN §6.5/§7.3）
          Log.warn("#{label} 下场保存失败（#{e.class}: #{e.message}）：失效让位，下次调用从最后已提交快照继续")
          invalidate!
          re_dispatch(queued)
          return
        end
      end
      release_ownership_if_held
      @troupe.events.publish(:offstaged, role_id: @role_id, stage_name: @stage_name)
      @manager.remove_cell(self)
      re_dispatch(queued)
    end

    def wait_turns_settle!
      @turn_lock.synchronize do
        while @in_flight.positive?
          @turn_cv.wait(@turn_lock, 0.02)
        end
      end
    end

    def release_ownership_if_held
      return unless @fencing_token.positive? && @troupe.prop_store.ownership_enabled?

      @troupe.prop_store.release_ownership(@namespace, @role_id, @stage_name,
                                           owner: @troupe.owner_id, expected_epoch: @fencing_token)
    rescue StandardError => e
      Log.warn("#{label} 释放所有权失败：#{e.message}（租约到期自愈）")
    end

    def re_dispatch(queued)
      queued.each do |call|
        Thread.new do
          begin
            @manager.deliver(call)
          rescue StandardError => e
            call.box.settle_error(e) unless call.box.settled?
          end
        end
      end
    end

    def fail_all_queued!(template)
      @board.drain_all!.each do |call|
        call.box.settle_error(template.class.new(template.message))
      end
    end

    def invalidate!
      @lock.synchronize do
        @state = :invalid
        @state_cv.broadcast
      end
      cancel_cues
      @actor = nil
      @troupe.events.publish(:invalid, role_id: @role_id, stage_name: @stage_name)
    end

    # ---- 内存 Cue（随实例下场消失，DESIGN §3.3） ----

    def register_cue(name, every, blk)
      every_s = Util.parse_duration(every, "cue 周期")
      state = @lock.synchronize { @state }
      if state == :draining || state == :invalid
        raise InvalidActorStateError, "#{label} 不在场，无法注册 Cue #{name.inspect}"
      end

      sleeper = Util::Sleeper.new
      @cue_lock.synchronize do
        old = @cues[name]
        old && old[:sleeper]&.cancel
        @cues[name] = { sleeper: sleeper, thread: nil }
      end
      t = Thread.new do
        begin
          Thread.current.name = "troupe-cue-#{@role_id}-#{name}"
        rescue StandardError
          nil
        end
        loop do
          break if sleeper.sleep(every_s) # cancel → 退出
          break if @stop_requested

          deadline = Util.now_ms + (Util.parse_duration(@troupe.config.call_timeout, "超时") * 1000).to_i
          cue_call = Call.new(namespace: @namespace, role_id: @role_id, stage_name: @stage_name,
                              method: :__cue__, args: [], deadline_ms: deadline,
                              source: :cue, block: blk, internal: true)
          begin
            @board.push!(cue_call)
          rescue BoardFullError => e
            Log.warn("#{label} cue #{name.inspect} 投递被拒（#{e.message}），本轮跳过")
          end
        end
      rescue StandardError => e
        Log.error("#{label} cue #{name.inspect} 异常退出：#{e.class}: #{e.message}")
      end
      @cue_lock.synchronize { @cues[name][:thread] = t }
      nil
    end

    def cancel_cue(name)
      @cue_lock.synchronize do
        entry = @cues.delete(name)
        entry && entry[:sleeper]&.cancel
      end
      nil
    end

    def cancel_cues
      @cue_lock.synchronize do
        @cues.each_value { |e| e[:sleeper]&.cancel }
        threads = @cues.values.filter_map { |e| e[:thread] }
        @cues.clear
        threads
      end.each { |t| t.join(0.2) }
      nil
    end

    # 提醒（CueStore 持久）注册入口
    def schedule_reminder(name, spec, payload)
      store = @troupe.cue_store
      raise ConfigError, "未配置 CueStore：schedule_reminder 需要持久提醒存储（DESIGN §7.5）" unless store

      @troupe.cue_scheduler.upsert_from_actor(@namespace, @role_id, @stage_name, name, spec, payload)
    end

    def cancel_reminder(name)
      store = @troupe.cue_store
      store&.cancel(Util.new_id(@namespace, @role_id, @stage_name, name))
    end
  end
end
