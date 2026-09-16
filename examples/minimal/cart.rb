# frozen_string_literal: true

# DESIGN.md §3.1 Cart 最小示例（Ruby 版）
# 运行：ruby examples/minimal/cart.rb
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "troupe"

# ---- 定义演员 ----

class CartActor < Troupe::Actor
  role_id "cart" # 稳定角色名：默认 = 类名去 "Actor" 后缀；持久业务建议显式声明
  intermission "10m"
  # 首次登台的初始状态（PropStore 无记录时使用；需要结构的 Props 必须提供工厂）
  # Props 用 JSON 边界语义：字符串键（本地/远程/Rehearsal 行为一致，DESIGN §6.1）
  initial_props { { "items" => [] } }

  def on_stage
    puts "[cart:#{stage_name}] 登台"
  end

  def off_stage
    save_props # 下场归还 Props（DESIGN §7.3）
    puts "[cart:#{stage_name}] 下场（已保存）"
  end

  def add(item)
    props["items"] << item
    save_props # 持久成功：提交成功后才返回
    nil
  end

  def peek
    props["items"].length
  end
end

# ---- 运行 ----

# 显式 InMemory 保持示例可重复运行；缺省为 PStorePropStore（./.troupe/props.pstore）
troupe = Troupe.form(actors: [CartActor], prop_store: :memory)

cart = troupe.cast(CartActor, "user-123") # Agent：类型面只有 RPC 方法
cart.add({ "sku" => "sku-1", "qty" => 1 })
cart.add({ "sku" => "sku-2", "qty" => 2 })
puts "peek() = #{cart.peek}" # 2

# Agent 表面验证（DESIGN §3.2）：白名单外成员不可经 RPC 调用
begin
  cart.props
rescue Troupe::CallRejectedError => e
  puts "agent.props  → 拒绝：#{e.message[0, 40]}…"
end
puts "agent.respond_to?(:add)   → #{cart.respond_to?(:add)}"
puts "agent.respond_to?(:save)  → #{cart.respond_to?(:save)}"

# 并发首调共享一次激活（single-flight，DESIGN §5.2）
t1 = Thread.new { cart.add({ "sku" => "sku-3", "qty" => 3 }) }
t2 = Thread.new { cart.add({ "sku" => "sku-4", "qty" => 4 }) }
t1.join
t2.join
puts "peek() = #{cart.peek}" # 4

# 交错执行标注组合矩阵的示例见 test/improv_test.rb 与 examples/drop_shop

troupe.drain_all # 排空：offStage + saveProps
troupe.shutdown!
puts "done"
