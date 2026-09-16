# frozen_string_literal: true

module Troupe
  # Edge（HTTP 接入，DESIGN §3.4/§10.1）：鉴权、参数校验、URL 实体 ID → (role, stageName) 映射
  # 三件事住在用户路由；本模块白送 /healthz、/metrics 与通用 /call 调试端点。
  # 基于 stdlib WEBrick（零 gem 依赖）；生产建议置于任意 Rack 服务器之后。
  class Edge
    def initialize(troupe, token: nil)
      @troupe = troupe
      @token = token
    end

    def start(port: 8080, host: "127.0.0.1")
      require "webrick"
      @server = WEBrick::HTTPServer.new(
        Port: port, BindAddress: host,
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::FATAL), AccessLog: []
      )
      @server.mount_proc("/healthz") do |_req, res|
        res["Content-Type"] = "application/json"
        res.body = JSON.generate({ "status" => "ok", "uptimeS" => @troupe.uptime_s, "stage" => @troupe.advertise })
      end
      @server.mount_proc("/metrics") do |_req, res|
        authorize!(req)
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(@troupe.metrics.snapshot)
      end
      @server.mount_proc("/call") do |req, res|
        authorize!(req)
        res["Content-Type"] = "application/json"
        begin
          raise CallRejectedError, "仅支持 POST" unless req.request_method == "POST"

          body = JSON.parse(req.body || "{}")
          role = body["role"].to_s
          stage_name = body["stageName"].to_s
          method = body["method"].to_s
          args = body["args"].is_a?(Array) ? body["args"] : []
          agent = @troupe.cast(role, stage_name)
          result = agent.with_timeout(body["timeout"] || @troupe.config.call_timeout).public_send(method, *args)
          res.body = JSON.generate({ "ok" => true, "result" => result })
        rescue TroupeError => e
          res.status = 400
          res.body = JSON.generate({ "ok" => false, "error" => { "kind" => e.kind.to_s, "message" => e.message } })
        rescue StandardError => e
          res.status = 500
          res.body = JSON.generate({ "ok" => false, "error" => { "kind" => "business", "message" => e.message } })
        end
      end
      @thread = Thread.new { @server.start }
      Log.info("Edge 监听 http://#{host}:#{port}（/healthz /metrics /call）")
    end

    def stop
      @server&.shutdown
      @thread&.join(1)
    end

    private

    def authorize!(req)
      return unless @token

      raise CallRejectedError, "需要 X-Troupe-Token" unless req.header["x-troupe-token"].first == @token
    end
  end
end
