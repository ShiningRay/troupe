# frozen_string_literal: true

require_relative "util"
require_relative "errors"
require_relative "config"
require_relative "codec"
require_relative "call"
require_relative "repertoire"
require_relative "actor"
require_relative "agent"
require_relative "trace"
require_relative "show"
require_relative "stage_manager"
require_relative "props/prop_store"
require_relative "props/pstore_store"
require_relative "cluster/roster"
require_relative "cluster/playbill"
require_relative "cluster/transport"
require_relative "cluster/hash_ring"
require_relative "cues/cue_store"
require_relative "cues/scheduler"
require_relative "director"

module Troupe
  MAX_FORWARD_HOPS = 2

  # Troupe（剧团）：一个进程 = 一个 Stage = 一个 Troupe 实例（DESIGN §4）。
  # 零配置启动：Troupe.form() 即自成一体；渐进式披露：每个旋钮都有默认值（DESIGN §8）。
  class Troupe
    attr_reader :config, :repertoire, :stage_manager, :prop_store, :cue_store,
                :cue_scheduler, :roster, :playbill, :transport, :trace, :metrics,
                :events, :incarnation

    def self.form(*args, **kwargs)
      opts = (args.first.is_a?(Hash) ? args.first : {}).merge(kwargs)
      Util.check_ruby_version!
      troupe = new(Config.resolve(opts), opts[:actors])
      troupe.start!
      troupe
    end

    def initialize(config, actors_spec = nil)
      @config = config
      @actors_spec = actors_spec
      @stopping = false
      @born_mono = Util.mono
      @incarnation = Util.incarnation
      @events = EventBus.new
      @metrics = Metrics.new
      @trace = TraceBus.new(capacity: config.trace_capacity, sample: config.trace_sample)
      @repertoire = build_repertoire
      @prop_store = build_prop_store
      @cue_store = build_cue_store
      @stage_manager = StageManager.new(self)
      @roster = Roster.new(self, seeds: config.seeds)
      @playbill = Playbill.new(self, @roster)
      @transport = config.transport_enabled ? Transport.new(self) : nil
      @cue_scheduler = @cue_store ? CueScheduler.new(self, @cue_store) : nil
      @director = Director.new(self)
      @shows = {}
      @shows_lock = Mutex.new
    end

    def start!
      @transport&.start
      @roster.start if @transport
      @cue_scheduler&.start
      start_ownership_heartbeat if @prop_store.ownership_enabled? && @config.ownership && @transport
      Log.info(
        "Troupe 上场：namespace=#{@config.namespace} stage=#{advertise} mode=#{@config.mode} " \
        "roles=[#{@repertoire.role_ids.sort.join(', ')}] store=#{@prop_store.class.name.split('::').last}"
      )
    end

    # 通告地址：集群内身份；Rehearsal（无传输）为虚拟地址
    def advertise
      @transport&.advertise || "rehearsal:#{@incarnation}"
    end

    # 所有权 owner 身份：地址 + incarnation（重启即新身份，DESIGN §6.2/§6.5）
    def owner_id
      "#{advertise}##{@incarnation}"
    end

    def stopping?
      @stopping
    end

    def uptime_s
      (Util.mono - @born_mono).round(1)
    end

    # ---- 调用面 ----

    # cast(ClassRef, stageName)：默认路径，零字符串；cast("Cart", stageName) 字符串逃生舱
    def cast(klass_or_role_id, stage_name, timeout: nil)
      klass =
        if klass_or_role_id.is_a?(Class)
          @repertoire[klass_or_role_id.role_id]
        else
          @repertoire[klass_or_role_id]
        end
      Agent.new(self, klass, stage_name, timeout)
    end

    # Agent 派发入口
    def dispatch_call(role_class, stage_name, method, args, timeout)
      raise CallRejectedError, "Troupe 正在停演：拒绝新 Call" if @stopping

      timeout_s = Util.parse_duration(timeout || @config.call_timeout, "call 超时")
      call = Call.new(
        namespace: @config.namespace, role_id: role_class.role_id, stage_name: stage_name,
        method: method, args: args, deadline_ms: Util.now_ms + (timeout_s * 1000).to_i,
        source: :local
      )
      route(call)
    end

    # 远端落地入口（transport → 这里）
    def dispatch_inbound(call)
      route(call)
    end

    # Playbill 寻址（DESIGN §5.1/§6.3）：归我 → 本地；不归我 → 转发（跳数上限 2）
    def route(call)
      return @stage_manager.deliver(call) if @transport.nil?

      owner = @playbill.owner_address(call.namespace, call.role_id, call.stage_name)
      if owner.nil? || owner == @transport.advertise
        @stage_manager.deliver(call)
      elsif call.hop >= MAX_FORWARD_HOPS
        raise CallRejectedError,
              "转发跳数上限（#{MAX_FORWARD_HOPS}）：环视图漂移未收敛，请求被拒绝（DESIGN §6.3）"
      else
        call.hop = call.hop + 1
        @transport.forward(owner, call)
      end
    end

    # ---- Show（进程内 pub/sub，DESIGN §2） ----

    def show(name)
      @shows_lock.synchronize { @shows[name.to_s] ||= Show.new(name.to_s) }
    end

    # ---- 生命周期 ----

    # quiesce（DESIGN §5.2）：等待所有运行中请求与框架回调结束
    def quiesce(timeout: nil)
      @stage_manager.quiesce(Util.parse_duration(timeout || @config.shutdown_grace, "grace"))
    end

    # 排空全部在场演员（offStage + saveProps），不停传输——测试与演示用
    def drain_all(timeout: 10.0)
      @stage_manager.drain_all_cells(timeout)
    end

    # 优雅停机（DESIGN §8.2）：拒新 Call → 排干 → 全员 offStage+saveProps → 退出 Roster
    def shutdown!(grace: nil)
      return if @stopping

      @stopping = true
      grace_s = Util.parse_duration(grace || @config.shutdown_grace, "grace")
      Log.info("优雅停机开始（grace=#{grace_s}s）")
      @transport&.stop
      @cue_scheduler&.stop
      @hb_sleeper&.cancel
      @stage_manager.shutdown(grace_s)
      @roster&.stop
      @prop_store&.close
      Log.info("Troupe 已停演（#{@config.namespace}）")
    end

    def director
      @director
    end

    private

    def build_repertoire
      if @actors_spec.nil?
        Repertoire.default.snapshot # performs! 进程级注册表快照（DESIGN §8.3）
      else
        Repertoire.new(@actors_spec)
      end
    end

    def build_prop_store
      case spec = @config.prop_store_spec
      when PropStore then spec
      when :memory, "memory" then MemoryPropStore.new
      when :pstore, "pstore", nil then PStorePropStore.new(File.join(@config.props_dir, "props.pstore"))
      when :sqlite, "sqlite" then require_sqlite; SqlitePropStore.new(File.join(@config.props_dir, "props.db"))
      when String
        uri = spec
        if uri.start_with?("postgres://", "postgresql://")
          raise ConfigError,
                "Ruby 版尚未内置 PostgresPropStore（多节点共享存储，路线图 item M3-eq）；" \
                "当前可单机运行（pstore/sqlite），集群强一致场景请暂用 Troupe.js"
        elsif uri.start_with?("sqlite://", "sqlite3://")
          require_sqlite
          SqlitePropStore.new(uri.sub(%r{\Asqlite3?://}, ""))
        elsif uri.start_with?("pstore://")
          PStorePropStore.new(uri.sub(%r{\Apstore://}, ""))
        else
          raise ConfigError, "未知 PropStore 连接串：#{uri.inspect}（支持 pstore:// / sqlite:// / postgres://）"
        end
      else
        raise ConfigError, "未知 PropStore spec：#{spec.inspect}"
      end
    end

    def require_sqlite
      require_relative "props/sqlite_store"
    end

    def build_cue_store
      case @config.cue_store_spec
      when CueStore then @config.cue_store_spec
      when :memory, "memory" then MemoryCueStore.new
      when :pstore, "pstore", nil then PstoreCueStore.new(File.join(@config.props_dir, "cues.pstore"))
      when false then nil
      else raise ConfigError, "未知 CueStore spec：#{@config.cue_store_spec.inspect}"
      end
    end

    # 所有权租约心跳（DESIGN §6.5）：续租失败 = 被顶替 → 停止接单并排空
    def start_ownership_heartbeat
      lease_s = Util.parse_duration(@config.ownership_lease, "租约")
      interval = [lease_s / 3.0, 0.1].max
      lease_ms = (lease_s * 1000).to_i
      @hb_sleeper = Util::Sleeper.new
      Thread.new do
        begin
          Thread.current.name = "troupe-ownership-hb"
        rescue StandardError
          nil
        end
        loop do
          break if @hb_sleeper.sleep(interval)

          @stage_manager.cells_snapshot.each do |cell|
            next unless cell.running? && cell.fencing_token.positive?

            ok = @prop_store.renew_ownership(cell.namespace, cell.role_id, cell.stage_name,
                                             owner: owner_id, expected_epoch: cell.fencing_token,
                                             lease_ms: lease_ms)
            unless ok
              Log.warn("所有权丢失：#{cell.label}（租约被顶替）→ 停止接单并排空，保存将被 fencing 拒绝（DESIGN §6.5）")
              cell.request_drain!(:ownership_lost)
            end
          end
        end
      rescue StandardError => e
        Log.error("所有权心跳线程退出：#{e.class}: #{e.message}")
      end
    end
  end

  # 模块级门面：Troupe.form(...)（Ruby 里模块与集群句柄类同名，
  # 与 Troupe.js 的顶层 Troupe 类保持同一 API 形态）
  def self.form(*args, **kwargs)
    opts = (args.first.is_a?(Hash) ? args.first : {}).merge(kwargs)
    ::Troupe::Troupe.form(**opts)
  end
end
