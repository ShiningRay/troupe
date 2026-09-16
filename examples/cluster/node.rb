# frozen_string_literal: true

# 双节点集群演示（DESIGN §8.4 集群零配置阶梯）
#
#   终端 1：TROUPE_PORT=7301 ruby examples/cluster/node.rb
#   终端 2：TROUPE_PORT=7302 TROUPE_SEEDS=127.0.0.1:7301 ruby examples/cluster/node.rb
#   任意终端：TROUPE_PORT=7303 TROUPE_SEEDS=127.0.0.1:7301 ruby examples/cluster/node.rb call
#   管理：   ruby bin/troupe --to 127.0.0.1:7301 status / ps / ring / tail
#
# 两个节点用同一个 HashRing 决定 (role, stageName) 归属；跨节点 cast 位置透明。
# 演示用内存 PropStore（进程级、各自独立）；真实多节点共享持久化见 DESIGN_NOTES 路线图。
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "troupe"

class HelloActor < Troupe::Actor
  initial_props { { "greetings" => 0 } }

  def say(name)
    props["greetings"] += 1
    save_props
    "你好, #{name}（第 #{props['greetings']} 次问候）"
  end

  def greeted
    props["greetings"]
  end
end

troupe = Troupe.form(actors: [HelloActor], prop_store: :memory)
puts "== node #{troupe.advertise} (namespace=#{troupe.config.namespace})"

# 等 join 收敛（seeds 可达时已入团），避免环漂移期本地激活与归属 Stage 双活
if troupe.config.seeds.any? && !troupe.roster.joined?
  puts "等待入团（seeds=#{troupe.config.seeds.join(',')}）…"
  deadline = Troupe::Util.mono + Troupe::Util.parse_duration(troupe.config.join_timeout, "join 超时")
  sleep 0.2 until troupe.roster.joined? || Troupe::Util.mono >= deadline
end

case ARGV[0] || "loop"
when "loop"
  hello = troupe.cast("Hello", "greeting")
  i = 0
  stop = false
  trap("INT") { stop = true }
  until stop
    i += 1
    owner = troupe.playbill.owner_address(troupe.config.namespace, "Hello", "greeting")
    puts "[#{i}] #{hello.say('cluster')}  owner=#{owner}"
    sleep 1
  end
  troupe.shutdown!
when "call"
  hello = troupe.cast("Hello", "greeting")
  puts hello.say("one-shot")
  puts "greeted = #{hello.greeted}"
  troupe.shutdown!
else
  warn "用法：ruby node.rb [loop|call]"
  troupe.shutdown!
end
