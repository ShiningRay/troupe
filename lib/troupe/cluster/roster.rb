# frozen_string_literal: true

require_relative "../util"

module Troupe
  # Roster（剧团花名册，DESIGN §6.2）：传播与探测分离，非完整 SWIM。
  #
  # 传播（反熵 gossip）：周期与随机已知 Stage 交换摘要；合并规则——
  # incarnation 更大直接采纳（重启即新身份）；同 incarnation 下 dead/left 为终态
  # 不能被旧 alive 复活；其余状态变化接受（suspect 可被在场证据反驳）。
  #
  # 探测（直接探测 + ACK）：周期 ping 环序相邻的 k 个成员，超时进 suspect，
  # suspect 超时未被反驳 → confirmed dead（终态）→ 摘环。
  class Roster
    SUSPECT_TIMEOUT = 5.0
    PROBE_INTERVAL = 2.0
    GOSSIP_INTERVAL = 1.0
    PROBE_FANOUT = 2
    RETAIN_DEAD = 300 # 死亡记录保留期（秒）

    attr_reader :self_incarnation

    def initialize(troupe, seeds: [])
      @troupe = troupe
      @seeds = seeds.compact.map(&:to_s).reject(&:empty?)
      @lock = Mutex.new
      @members = {}
      @version = 1
      @self_incarnation = Util.incarnation
      @joined = @seeds.empty?
      @join_failure_logged = false
      @stopped = false
      @sleeper = Util::Sleeper.new
    end

    def self_addr
      @troupe.advertise
    end

    def joined?
      @joined
    end

    def start
      @thread = Thread.new do
        begin
          Thread.current.name = "troupe-roster"
        rescue StandardError
          nil
        end
        join_loop
        loop do
          break if @sleeper.sleep(GOSSIP_INTERVAL)
          break if @stopped

          gossip_tick
          probe_tick if ((Util.now_ms / 1000) % 2).zero? # 探测周期 2s
        end
      rescue StandardError => e
        Log.error("roster 线程退出：#{e.class}: #{e.message}")
      end
    end

    def stop
      @stopped = true
      @sleeper.cancel
    end

    # ---- 视图 ----

    # 环视图：自己 + 存活（含 suspect，确认 dead 才摘环）
    def view
      @lock.synchronize do
        addrs = [self_addr]
        now = Util.now_ms
        @members.each do |addr, m|
          next if %w[dead left].include?(m[:status])
          # 死亡保留期内同地址旧身份不复活；过期 tombstone 清理
          if m[:status] == "dead" && now - m[:since] > RETAIN_DEAD * 1000
            @members.delete(addr)
            next
          end
          addrs << addr
        end
        { version: @version, addresses: addrs.uniq }
      end
    end

    def alive_peers
      @lock.synchronize do
        @members.select { |_, m| m[:status] == "alive" }.keys
      end
    end

    def summary
      @lock.synchronize do
        recs = [{
          "addr" => self_addr, "incarnation" => @self_incarnation, "status" => "alive",
          "roles" => @troupe.repertoire.role_ids.sort, "protocol" => PROTOCOL_VERSION,
          "since" => Util.now_ms
        }]
        @members.each do |addr, m|
          recs << { "addr" => addr, "incarnation" => m[:incarnation], "status" => m[:status],
                    "roles" => m[:roles], "protocol" => m[:protocol], "since" => m[:since] }
        end
        recs
      end
    end

    def stage_infos
      @lock.synchronize do
        recs = [{ "addr" => self_addr, "incarnation" => @self_incarnation, "status" => "self",
                  "roles" => @troupe.repertoire.role_ids.sort }]
        @members.each { |addr, m| recs << { "addr" => addr, "incarnation" => m[:incarnation], "status" => m[:status], "roles" => m[:roles] } }
        recs
      end
    end

    # ---- 合并（单调规则） ----

    def merge(records)
      changed = false
      Array(records).each do |r|
        addr = r["addr"].to_s
        next if addr.empty? || addr == self_addr

        inc = r["incarnation"].to_s
        status = r["status"].to_s
        unless %w[alive suspect dead left].include?(status)
          Log.warn("roster 忽略未知状态 #{status.inspect}（#{addr}）")
          next
        end

        @lock.synchronize do
          cur = @members[addr]
          if cur.nil?
            @members[addr] = { incarnation: inc, status: status, roles: Array(r["roles"]), protocol: r["protocol"], since: Util.now_ms }
            changed = true
          elsif inc > cur[:incarnation]
            # 新 incarnation = 新身份：旧记录（含终态）一律让位
            @members[addr] = { incarnation: inc, status: status, roles: Array(r["roles"]), protocol: r["protocol"], since: Util.now_ms }
            changed = true
          elsif inc == cur[:incarnation]
            # 同 incarnation：dead/left 终态不可复活（反复转发的旧 alive 不能复活已确认死亡）
            unless %w[dead left].include?(cur[:status])
              if status != cur[:status]
                cur[:status] = status
                cur[:since] = Util.now_ms if status == "suspect"
                changed = true
              elsif status == "alive"
                cur[:refuted_at] = Util.now_ms # suspect 的在场反驳
              end
            end
          end
        end
      end
      @lock.synchronize { @version += 1 } if changed
      changed
    end

    # ---- join / gossip / probe ----

    def join_loop
      return if @joined

      deadline = Util.now_ms + (Util.parse_duration(@troupe.config.join_timeout, "join 超时") * 1000).to_i
      loop do
        @seeds.each do |seed|
          next if seed == self_addr

          begin
            peer = @troupe.transport.sync(seed, summary, timeout: 1.5)
            merge(peer)
            @joined = true
            Log.info("已入团：seed=#{seed}")
            return
          rescue StandardError => e
            Log.debug("join #{seed} 失败：#{e.message}")
          end
        end
        break if @joined
        if Util.now_ms >= deadline
          if @troupe.config.require_cluster
            raise ConfigError, "production 模式必须成功入团（--require-cluster 语义）：seeds=#{@seeds.join(',')} 全部不可达"
          end
          unless @join_failure_logged
            Log.warn("seeds 全部不可达：dev 模式自成一团（若非预期请检查 TROUPE_SEEDS）")
            @join_failure_logged = true
          end
          return
        end
        sleep 0.5
      end
    end

    def gossip_tick
      peer = @lock.synchronize do
        candidates = @members.select { |_, m| m[:status] != "dead" }.keys
        candidates.sample
      end
      unless peer
        # 尚无成员：重试 join（seeds 可能恢复）
        join_loop unless @joined
        return
      end
      peer_summary = @troupe.transport.sync(peer, summary, timeout: 1.5)
      merge(peer_summary)
    rescue StandardError => e
      Log.debug("gossip #{peer} 失败：#{e.message}")
    end

    def probe_tick
      targets = ring_neighbors(PROBE_FANOUT)
      targets.each do |addr|
        begin
          @troupe.transport.ping(addr, timeout: 1.0)
          refute(addr)
        rescue StandardError
          suspect(addr)
        end
      end
    end

    # 环序相邻的 k 个存活成员（直接探测目标）
    def ring_neighbors(k)
      addrs = (@lock.synchronize do
        @members.select { |_, m| m[:status] == "alive" }.keys.sort
      end)
      return [] if addrs.empty?

      idx = addrs.bsearch_index { |a| a >= self_addr } || 0
      (1..k).map { |i| addrs[(idx + i) % addrs.size] }.uniq
    end

    def refute(addr)
      @lock.synchronize do
        m = @members[addr]
        return if m.nil? || %w[dead left].include?(m[:status])

        if m[:status] != "alive"
          m[:status] = "alive"
          @version += 1
        end
        m[:refuted_at] = Util.now_ms
      end
    end

    def suspect(addr)
      @lock.synchronize do
        m = @members[addr]
        return if m.nil? || %w[dead left].include?(m[:status])

        m[:status] = "suspect"
        m[:since] ||= Util.now_ms
        @version += 1
      end
      @lock.synchronize do
        m = @members[addr]
        if m && m[:status] == "suspect" && Util.now_ms - m[:since] > SUSPECT_TIMEOUT * 1000
          m[:status] = "dead" # confirmed：终态，摘环
          m[:since] = Util.now_ms
          @version += 1
          Log.warn("成员确认死亡：#{addr}（已摘环，死亡记录保留 #{RETAIN_DEAD}s）")
        end
      end
    end
  end
end
