# frozen_string_literal: true

# DESIGN.md §10.3 参考示例：限量发售（秒杀）——Ruby 版
# 单机：ruby examples/drop_shop/shop.rb
# HTTP：ruby examples/drop_shop/shop.rb --http 8080  然后 curl 见 README
#
# 语义要点：
# * 热点 SKU 扣减 = 单 Actor 串行内存操作（无 DB 行锁 / Redis Lua）
# * 持久成功：库存变更 + 幂等记录原子提交后才返回成功（响应即已落盘）
# * 幂等重放：同 requestId 同参数返回原结果；同键不同参数拒绝（DESIGN §6.5）
# * 状态冷知识：Props 用字符串键（JSON 边界）
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "troupe"

class InventoryActor < Troupe::Actor
  intermission "5m"
  schema_version 1
  initial_props { { "remaining" => 0, "reserved_by" => {}, "dirty_ops" => 0 } }

  def on_stage
    # 攒批冲刷（可选模式：接受 RPO = flush 间隔的丢失窗口并显式标注）
    register_cue("flush", "2s") { flush }
    # 幂等记录保留期限清理（默认 7 天）
    schedule_reminder("gc", "1h", payload: { "kind" => "gc" })
  end

  def on_cue(name, _payload)
    gc_reserved if name == "gc"
  end

  # reserve(requestId, qty)——业务幂等 + 持久成功（DESIGN §10.3）
  def reserve(request_id, qty)
    seen = props["reserved_by"][request_id]
    if seen
      raise Troupe::IdempotencyConflictError, "requestId=#{request_id} 已用于不同参数（#{seen} ≠ #{qty}）" if seen != qty

      return { "ok" => true, "remaining" => props["remaining"], "replayed" => true } # 幂等重放
    end
    return { "ok" => false, "remaining" => props["remaining"] } if props["remaining"] < qty

    props["remaining"] -= qty
    props["reserved_by"][request_id] = qty
    props["dirty_ops"] += 1
    save_props # 持久成功：库存变更 + 幂等记录原子提交后才返回成功
    { "ok" => true, "remaining" => props["remaining"] }
  end

  def available
    props["remaining"]
  end

  def restock(n)
    props["remaining"] += n
    props["dirty_ops"] += 1
    save_props
    props["remaining"]
  end

  private

  # 攒批冲刷：只对未 save 的脏操作兜底（持久成功路径不经过这里）
  def flush
    save_props if props["dirty_ops"].positive?
  end

  def gc_reserved
    cutoff = Troupe::Util.now_ms - 7 * 86_400_000 # 7 天保留期
    props["reserved_by"].reject! { |_k, v| v.is_a?(Hash) && v["at"] && v["at"] < cutoff }
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  http_port = ARGV.index("--http") && Integer(ARGV[ARGV.index("--http") + 1])
  troupe = Troupe.form(actors: [InventoryActor], prop_store: :memory)

  sku = troupe.cast(InventoryActor, "sku-1001")
  puts "上架 100 件 → remaining = #{sku.restock(100)}"

  3.times do |i|
    result = sku.reserve("req-#{i}", 2)
    puts "reserve(req-#{i}, 2) → #{result.inspect}"
  end
  # 幂等重放：同键同参数
  puts "reserve(req-0, 2) 重放 → #{sku.reserve('req-0', 2).inspect}"
  # 同键不同参数拒绝
  begin
    sku.reserve("req-0", 5)
  rescue Troupe::IdempotencyConflictError => e
    puts "reserve(req-0, 5) → 拒绝：#{e.message}"
  end
  puts "available = #{sku.available}"

  if http_port
    require "troupe/edge"
    edge = Troupe::Edge.new(troupe)
    edge.start(port: http_port)
    puts "Edge: POST http://127.0.0.1:#{http_port}/call  " \
         '{ "role": "Inventory", "stageName": "sku-1001", "method": "reserve", "args": ["req-9", 1] }'
    sleep
  else
    troupe.drain_all
    troupe.shutdown!
  end
end
