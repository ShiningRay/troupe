# frozen_string_literal: true

require_relative "call"
require_relative "errors"

module Troupe
  # Director（导演，DESIGN §11.1）：每 Stage 自动内建的系统内省角色。
  # 不在用户 Repertoire、无 Props/Intermission、不可 cast；CLI 与 Booth 都是它的瘦客户端。
  # 集群级查询经它向其他 Stage 的 Director 扇出聚合（扇出携带已验证的权限上下文）。
  class Director
    ROLE_ID = "__director__"

    METHODS = %w[status roster actors inspect invoke off ring cues metrics trace].freeze

    def initialize(troupe)
      @troupe = troupe
      @born_mono = Util.mono
    end

    def handle(method, args = [])
      args = Array(args)
      case method.to_s
      when "status" then status(truthy?(args[0]))
      when "roster" then roster_info(truthy?(args[0]))
      when "actors" then actors(truthy?(args[0]), args[1])
      when "inspect" then inspect(args[0].to_s, args[1].to_s)
      when "invoke" then invoke(args[0].to_s, args[1].to_s, args[2].to_s, args[3].is_a?(Array) ? args[3] : [])
      when "off" then off(args[0].to_s, args[1].to_s)
      when "ring" then @troupe.playbill.distribution
      when "cues" then cues(truthy?(args[0]))
      when "metrics" then @troupe.metrics.snapshot
      when "trace" then @troupe.trace.recent(Integer(args[0] || 100))
      else
        raise UnknownMethodError, "Director 无此方法 #{method.inspect}（可用：#{METHODS.join(' ')}）"
      end
    end

    def status(cluster = false)
      local = {
        "stage" => @troupe.advertise, "mode" => @troupe.config.mode, "namespace" => @troupe.config.namespace,
        "incarnation" => @troupe.incarnation, "uptimeS" => (Util.mono - @born_mono).round(1),
        "actorsOn" => @troupe.stage_manager.cell_count, "queuedBytes" => @troupe.stage_manager.queued_bytes,
        "roles" => @troupe.repertoire.role_ids.sort, "protocol" => PROTOCOL_VERSION,
        "joined" => @troupe.roster.joined?, "ownerId" => @troupe.owner_id
      }
      return local unless cluster

      stages = [local] + fan_out("status", []).filter_map do |entry|
        entry["error"] or entry["result"]
      end
      { "stage" => @troupe.advertise, "stages" => stages }
    end

    def roster_info(_cluster = false)
      @troupe.roster.stage_infos
    end

    # 在场演员列表；cluster=true 时扇出聚合（含本 Stage，ps 数据源）
    def actors(cluster = false, filter = nil)
      local = filter_items(@troupe.stage_manager.actors_info, filter)
      return local unless cluster

      mine = local.map { |a| a.merge("stage" => @troupe.advertise) }
      peers = fan_out("actors", [nil, filter]).flat_map do |entry|
        if entry["error"]
          [{ "stage" => entry["stage"], "error" => entry["error"] }]
        else
          entry["result"].map { |a| a.merge("stage" => entry["stage"]) }
        end
      end
      mine + peers
    end

    def inspect(role, stage_name)
      detail = @troupe.stage_manager.inspect_cell(role, stage_name)
      raise CallRejectedError, "演员不在场：#{role}/#{stage_name}（inspect 只能看到本 Stage 在场实例）" unless detail

      detail
    end

    # 管理调用：同样走 Actor 调度约束（白名单适用、不旁路串行规则，DESIGN §5.2/§11.1）
    def invoke(role, stage_name, method, args)
      call = Call.new(
        namespace: @troupe.config.namespace, role_id: role, stage_name: stage_name,
        method: method, args: args,
        deadline_ms: Util.now_ms + (Util.parse_duration(@troupe.config.call_timeout, "超时") * 1000).to_i,
        source: :admin
      )
      @troupe.stage_manager.deliver(call)
    end

    def off(role, stage_name)
      { "off" => @troupe.stage_manager.admin_off(role, stage_name) }
    end

    def cues(cluster = false)
      local = @troupe.cue_store&.list || []
      return local unless cluster

      fan_out("cues", []).flat_map do |entry|
        entry["error"] ? [{ "stage" => entry["stage"], "error" => entry["error"] }] : entry["result"]
      end
    end

    private

    def truthy?(v)
      v == true || v == "true" || v == 1 || v == "1"
    end

    def filter_items(items, filter)
      return items unless filter.is_a?(Hash)

      items.select do |it|
        (filter["role"].nil? || it["role"] == filter["role"]) &&
          (filter["stageName"].nil? || it["stageName"] == filter["stageName"])
      end
    end

    # 扇出聚合：首个入口鉴权后携带已验证上下文（此处为已通过 Director 鉴权的调用）
    def fan_out(method, args, timeout: 3.0)
      peers = @troupe.roster.alive_peers
      entries = peers.map do |peer|
        Thread.new do
          { "stage" => peer, "result" => @troupe.transport.director_call(peer, method, args, timeout: timeout) }
        rescue StandardError => e
          { "stage" => peer, "error" => "#{e.class}: #{e.message}" }
        end
      end
      entries.map(&:value)
    end
  end
end
