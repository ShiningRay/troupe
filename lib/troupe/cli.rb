# frozen_string_literal: true

require "json"
require "socket"
require_relative "../troupe"

module Troupe
  # CLI：`troupe <cmd>`（DESIGN §11.2）。手写参数解析、零依赖；
  # CLI 与 Booth 一样，都是 Director 的瘦客户端——客户端永远只连一个点。
  class CLI
    DEFAULT_TO = "127.0.0.1:7300"

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      @to = DEFAULT_TO
      @json = false
      @token = ENV["TROUPE_ADMIN_TOKEN"]
      @interval = 2.0
      cmd, rest = parse(argv)
      return 2 unless cmd

      case cmd
      when "help", nil
        usage
        cmd.nil? ? 2 : 0
      when "status" then render("status", [flag(rest, "--cluster")])
      when "roster" then render("roster", [])
      when "ps" then ps(rest)
      when "inspect"
        role, name = rest
        render("inspect", [role, name])
      when "call"
        role, name, method, args_json = rest
        args = args_json ? JSON.parse(args_json) : []
        render("invoke", [role, name, method, args])
      when "off"
        role, name = rest
        render("off", [role, name])
      when "ring" then render("ring", [])
      when "cues" then render("cues", [flag(rest, "--cluster")])
      when "metrics" then render("metrics", [])
      when "tail" then tail(rest)
      when "top" then top(rest)
      else
        warn "未知命令：#{cmd}"
        usage
        2
      end
    rescue Errno::ECONNREFUSED, SocketError => e
      warn "无法连接 #{@to}：#{e.message}（--to host:port 指定目标；默认 #{DEFAULT_TO}）"
      1
    rescue Interrupt
      0
    end

    private

    def parse(argv)
      rest = []
      until argv.empty?
        a = argv.shift
        case a
        when "--to" then @to = argv.shift
        when /\A--to=(.*)\z/ then @to = Regexp.last_match(1)
        when "--json" then @json = true
        when "--token", "--admin" then @token = argv.shift
        when /\A--token=(.*)\z/, /\A--admin=(.*)\z/ then @token = Regexp.last_match(1)
        when "--interval" then @interval = Float(argv.shift)
        when /\A--interval=(.*)\z/ then @interval = Float(Regexp.last_match(1))
        else rest << a
        end
      end
      [rest.shift, rest]
    end

    def flag(rest, name)
      rest.delete(name) ? true : false
    end

    def client
      host, port = @to.split(":", 2)
      @client ||= DirectorClient.new(host, Integer(port || 7300), @token)
    end

    def render(method, args)
      result = client.director(method, args)
      puts @json ? JSON.pretty_generate(result) : send(:"format_#{method}", result)
      0
    end

    def ps(rest)
      role = opt_value(rest, "--role")
      stage = opt_value(rest, "--stage")
      filter = {}
      filter["role"] = role if role
      filter["stageName"] = stage if stage
      rows = client.director("actors", [true, filter])
      if @json
        puts JSON.pretty_generate(rows)
        return 0
      end
      puts format_table(
        %w[ROLE STAGE_NAME STATE STAGE DEPTH REV TOKEN IDLE_S],
        rows.map do |a|
          [a["role"], a["stageName"], a["state"], a["stage"] || "?", a["callBoardDepth"], a["revision"], a["fencingToken"], a["intermissionIn"]]
        end
      )
      0
    end

    def tail(rest)
      role = opt_value(rest, "--role")
      method = opt_value(rest, "--method")
      filter = {}
      filter["role"] = role if role
      filter["method"] = method if method
      client.stream(filter) do |ev|
        puts format("%s  %-18s %-12s %-14s %8sms  %s",
                    Time.at(ev["at"] / 1000.0).strftime("%H:%M:%S"),
                    "#{ev['role']}/#{ev['stageName']}", ev["method"], ev["from"].to_s[0, 14],
                    ev["durationMs"], ev["outcome"])
      end
      0
    end

    def top(rest)
      trap("INT") { exit 0 }
      loop do
        rows = client.director("actors", [true, nil])
          .select { |a| a["role"] }
          .sort_by { |a| -(a["callBoardDepth"] || 0) }
          .first(20)
        puts "\e[2J\e[Htroupe top — #{@to}  #{Time.now.strftime('%H:%M:%S')}"
        puts format_table(%w[ROLE STAGE_NAME STATE STAGE DEPTH IDLE_S], rows.map do |a|
          [a["role"], a["stageName"], a["state"], a["stage"], a["callBoardDepth"], a["intermissionIn"]]
        end)
        metrics = client.director("metrics", [])
        hot = metrics.sort_by { |_, m| -(m["calls"] || 0) }.first(10)
        puts format_table(%w[ROLE CALLS ERRORS REJECTED P50MS P99MS], hot.map do |r, m|
          [r, m["calls"], m["errors"], m["rejected"], m["p50ms"], m["p99ms"]]
        end)
        sleep @interval
      end
    end

    def opt_value(rest, name)
      i = rest.index(name)
      return nil unless i

      v = rest[i + 1]
      rest.delete_at(i)
      rest.delete_at(i)
      v
    end

    # ---- 格式化 ----

    def format_status(s)
      if s["stages"]
        format_table(%w[STAGE MODE UPTIME_S ACTORS ROLES], s["stages"].map do |e|
          e["error"] ? [e["stage"], "ERROR", e["error"][0, 40], "-", "-"] : format_status_row(e["result"])
        end)
      else
        format_table(%w[STAGE MODE UPTIME_S ACTORS ROLES], [format_status_row(s)])
      end
    end

    def format_status_row(s)
      [s["stage"], s["mode"], s["uptimeS"], s["actorsOn"], Array(s["roles"]).join(",")]
    end

    def format_roster(rows)
      format_table(%w[ADDR STATUS INCARNATION ROLES], rows.map do |r|
        [r["addr"], r["status"], r["incarnation"], Array(r["roles"]).join(",")]
      end)
    end

    def format_inspect(d)
      JSON.pretty_generate(d)
    end

    def format_invoke(v)
      v.is_a?(String) ? v : JSON.pretty_generate(v)
    end

    def format_off(v)
      v["off"] ? "已下场" : "不在场（本 Stage）"
    end

    def format_ring(d)
      lines = ["虚拟节点总数：#{d['vnodes']}（每节点 #{d['vnodes'] / [d['nodes'].size, 1].max}）",
               "份额：min=#{d['minShare']} max=#{d['maxShare']}"]
      d["perNode"].each { |addr, n| lines << format("  %-24s %5d vnodes", addr, n) }
      lines.join("\n")
    end

    def format_cues(rows)
      return "(无 Cue)" if rows.empty?

      format_table(%w[ID SCHEDULE STATUS NEXT_DUE], rows.map do |c|
        [c["id"], c["schedule"], c["status"], Time.at(c["nextDue"] / 1000.0).strftime("%H:%M:%S")]
      end)
    end

    def format_metrics(m)
      return "(无数据)" if m.empty?

      format_table(%w[ROLE CALLS ERRORS REJECTED ACT P50 P99 MAX], m.map do |r, s|
        [r, s["calls"], s["errors"], s["rejected"], s["activations"], s["p50ms"], s["p99ms"], s["maxMs"]]
      end)
    end

    def format_table(headers, rows)
      cells = rows.map { |r| r.map { |c| c.nil? ? "-" : c.to_s } }
      widths = headers.each_with_index.map { |h, i| [h.length, *cells.map { |r| (r[i] || "").length }].max }
      line = ->(r) { r.each_with_index.map { |c, i| c.ljust(widths[i]) }.join("  ").rstrip }
      [line.call(headers), "─" * widths.sum { |w| w + 2 }].concat(cells.map { |r| line.call(r) }).join("\n")
    end

    def usage
      puts <<~USAGE
        troupe — Troupe.rb 管理客户端（Director 瘦客户端）

        连接：--to host:port（默认 #{DEFAULT_TO}）；--token TOKEN；--json

        命令：
          status [--cluster]            集群总览
          roster                        Stage 列表
          ps [--role R] [--stage S]     在场演员
          inspect <role> <stageName>    详情（含 Props 快照）
          call <role> <name> <m> [json] 调用演员方法（args 为 JSON 数组）
          off <role> <stageName>        强制下场
          ring                          哈希环分布
          cues [--cluster]              持久提醒
          metrics                       每角色计数器与延迟
          tail [--role R] [--method M]  实时调用事件流
          top                           动态刷新热点视图
      USAGE
    end
  end

  # CLI 独立瘦客户端：同一长度前缀 + JSON 帧协议，直接与 Director 对话
  class DirectorClient
    def initialize(host, port, token = nil)
      @host = host
      @port = port
      @token = token.to_s
      @sock = nil
      @wm = Mutex.new
    end

    def director(method, args, timeout: 5.0)
      connect_once unless @sock
      id = Util.call_id
      deadline = Util.now_ms + (timeout * 1000).to_i
      frame = {
        "t" => "call", "from" => "cli", "token" => @token,
        "call" => {
          "v" => PROTOCOL_VERSION, "callId" => id, "ns" => "-",
          "to" => { "role" => Director::ROLE_ID, "stageName" => "-" },
          "method" => method, "args" => args, "deadline" => deadline, "hop" => 0
        }
      }
      @wm.synchronize { write_frame(@sock, frame) }
      loop do
        resp = read_frame(@sock)
        next unless resp.is_a?(Hash) && resp["t"] == "resp" && resp["callId"] == id

        raise RemoteError.new(resp.dig("error", "name"), resp.dig("error", "message")) unless resp["ok"]

        return resp["result"]
      end
    end

    def stream(filter, &blk)
      connect_once unless @sock
      @wm.synchronize do
        write_frame(@sock, { "t" => "sub", "token" => @token, "filter" => filter })
        ack = read_frame(@sock)
        raise RemoteError.new("CallRejectedError", ack["message"].to_s) if ack.is_a?(Hash) && ack["ok"] == false
      end
      loop do
        frame = read_frame(@sock)
        yield frame["event"] if frame.is_a?(Hash) && frame["t"] == "trace"
      end
    end

    def close
      @sock&.close
      @sock = nil
    end

    private

    def connect_once
      @sock = TCPSocket.new(@host, @port)
    rescue StandardError => e
      raise Errno::ECONNREFUSED, e.message
    end

    def read_frame(sock)
      len = read_exact(sock, 4).unpack1("V")
      JSON.parse(read_exact(sock, len))
    end

    def read_exact(sock, n)
      buf = +"".b
      while buf.bytesize < n
        chunk = sock.read(n - buf.bytesize)
        raise EOFError, "连接关闭" unless chunk

        buf << chunk
      end
      buf
    end

    def write_frame(sock, obj)
      data = JSON.generate(obj)
      sock.write([data.bytesize].pack("V") + data)
    end
  end
end
