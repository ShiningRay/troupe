# frozen_string_literal: true

require "etc"
require_relative "util"

module Troupe
  # 零配置优先级链（DESIGN §8.1）：显式传参 > 环境变量 > 约定默认值
  class Config
    attr_accessor :mode, :rehearsal, :transport_enabled, :namespace,
                  :host, :port, :advertise, :seeds, :require_cluster, :join_timeout,
                  :call_timeout, :intermission, :cue_tick, :reminder_lease, :shutdown_grace,
                  :call_board_limit, :activation_limit, :queue_bytes_limit, :remote_workers,
                  :local_call_by_reference, :admin_token, :cluster_token,
                  :prop_store_spec, :cue_store_spec, :props_dir,
                  :ownership, :ownership_lease, :ownership_acquire_timeout,
                  :trace_sample, :trace_capacity, :improv_idle, :call_timeout_s,
                  :dispatcher, :dispatcher_threads

    def self.resolve(opts = {})
      opts = opts.transform_keys(&:to_sym)
      env = ENV
      cfg = new
      cfg.mode = opts[:mode] || env["TROUPE_MODE"] || "dev"
      cfg.rehearsal = opts.fetch(:rehearsal, env["TROUPE_ENV"] == "test")
      cfg.transport_enabled = opts.fetch(:transport, !cfg.rehearsal)
      cfg.namespace = opts[:namespace] || env["TROUPE_NAMESPACE"] || File.basename(Dir.pwd)
      cfg.host = opts[:host] || env["TROUPE_HOST"] || (cfg.mode == "production" ? "0.0.0.0" : "127.0.0.1")
      cfg.port = Integer(opts[:port] || env["TROUPE_PORT"] || 7300)
      cfg.advertise = opts[:advertise] || env["TROUPE_ADVERTISE"]
      cfg.seeds = parse_seeds(opts[:seeds] || env["TROUPE_SEEDS"])
      cfg.require_cluster = cfg.mode == "production" || !!opts[:require_cluster]
      cfg.join_timeout = opts[:join_timeout] || "10s"
      cfg.call_timeout = opts[:call_timeout] || "30s"
      cfg.intermission = opts[:intermission] || "5m"
      cfg.cue_tick = opts[:cue_tick] || "1s"
      cfg.reminder_lease = opts[:reminder_lease] || "15s"
      cfg.shutdown_grace = opts[:shutdown_grace] || env["TROUPE_SHUTDOWN_GRACE"] || "10s"
      cfg.call_board_limit = Integer(opts[:call_board_limit] || 1024)
      cfg.activation_limit = Integer(opts[:activation_limit] || 10_000)
      cfg.queue_bytes_limit = Integer(opts[:queue_bytes_limit] || (32 * 1024 * 1024))
      cfg.remote_workers = Integer(opts[:remote_workers] || 32)
      cfg.local_call_by_reference = !!opts[:local_call_by_reference]
      cfg.admin_token = opts[:admin_token] || env["TROUPE_ADMIN_TOKEN"]
      cfg.cluster_token = opts[:cluster_token] || env["TROUPE_CLUSTER_TOKEN"]
      cfg.props_dir = opts[:props_dir] || env["TROUPE_PROPS_DIR"] || "./.troupe"
      cfg.prop_store_spec = opts[:prop_store] || env["TROUPE_PROPSTORE"] || (cfg.rehearsal ? :memory : :pstore)
      cfg.cue_store_spec = opts[:cue_store] || (cfg.rehearsal ? :memory : :pstore)
      cfg.ownership = opts.fetch(:ownership, true)
      cfg.ownership_lease = opts[:ownership_lease] || "15s"
      cfg.ownership_acquire_timeout = opts[:ownership_acquire_timeout] || "10s"
      cfg.trace_sample = Float(opts[:trace_sample] || 1.0)
      cfg.trace_capacity = Integer(opts[:trace_capacity] || 10_000)
      cfg.improv_idle = Integer(opts[:improv_idle] || 32)

      # 调度模型（DESIGN §5.1 Ruby 适配）：:thread_per_cell（默认，每 Cell 一条调度线程，
      # 阻塞 Turn 隔离性最好）| :shared（M 条共享调度线程多路复用 Cell，激活/内存成本大降，
      # 语义差异见 SharedDispatcherPool 注释）
      cfg.dispatcher = opts[:dispatcher] || env["TROUPE_DISPATCHER"]&.to_sym || :thread_per_cell
      unless %i[thread_per_cell shared].include?(cfg.dispatcher)
        raise ConfigError, "未知 dispatcher：#{cfg.dispatcher.inspect}（支持 :thread_per_cell / :shared）"
      end
      cfg.dispatcher_threads =
        Integer(opts[:dispatcher_threads] || env["TROUPE_DISPATCHER_THREADS"] || [Etc.nprocessors, 8].min)

      # 热路径预解析：dispatch_call 每次调用都要用，不能每次都做字符串解析
      require_relative "util"
      cfg.call_timeout_s = Util.parse_duration(cfg.call_timeout, "call 超时")

      # production 前提（DESIGN §8.2）：显式 advertiseAddress
      if cfg.mode == "production" && cfg.transport_enabled && cfg.advertise.nil?
        raise ConfigError, "production 模式必须显式配置 advertiseAddress（TROUPE_ADVERTISE）：固定端口 + 显式通告地址"
      end
      cfg
    end

    def production?
      mode == "production"
    end

    def self.parse_seeds(spec)
      case spec
      when nil then []
      when Array then spec.map(&:to_s).map(&:strip).reject(&:empty?)
      else spec.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
