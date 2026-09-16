# frozen_string_literal: true

# cluster 远程往返：thread_per_cell vs shared 最小对比（bench-suite 排查用）
$LOAD_PATH.unshift(File.expand_path("lib"))
require "troupe"
$stdout.sync = true
require "logger"
Troupe::Log.logger.level = Logger::FATAL

class BenchPingActor < Troupe::Actor
  role_id "Bench"
  initial_props { { "n" => 0 } }
  def ping(payload) = payload
end

CHILD_SRC = <<~'CHILD'
  $LOAD_PATH.unshift(%s)
  require "troupe"
  require "logger"
  Troupe::Log.logger.level = Logger::FATAL
  class BenchPingActor < Troupe::Actor
    role_id "Bench"
    initial_props { { "n" => 0 } }
    def ping(payload) = payload
  end
  troupe = Troupe.form(actors: [BenchPingActor], prop_store: :memory, cue_store: :memory,
                       namespace: "bench_suite", port: 0, seeds: [%s])
  sleep 0.1 until troupe.roster.joined?
  puts "READY #{troupe.advertise}"
  $stdout.flush
  sleep 30
CHILD

def run_mode(mode)
  troupe = Troupe.form(actors: [BenchPingActor], prop_store: :memory, cue_store: :memory,
                       namespace: "bench_suite", port: 0, dispatcher: mode)
  r, w = IO.pipe
  src = format(CHILD_SRC, File.expand_path("lib").inspect, troupe.advertise.inspect)
  pid = Process.spawn(RbConfig.ruby, "-e", src, out: w)
  w.close
  child_addr = r.gets&.match(/^READY (\S+)/)&.[](1)
  raise "child not ready" unless child_addr

  key = (0...50_000).find { |i| troupe.playbill.owner_address("bench_suite", "Bench", "c#{i}") == child_addr }
  agent = troupe.cast("Bench", key)
  200.times { agent.ping("x") } # warmup
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  2000.times { agent.ping("x") }
  dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts "#{mode}: #{(2000 / dt).round} ops/s (#{(dt / 2000 * 1e6).round} us/op)"
  Process.kill("TERM", pid)
  Process.wait(pid)
  troupe.shutdown!
end

modes = ARGV.empty? ? %i[thread_per_cell shared thread_per_cell shared] : ARGV.map(&:to_sym)
modes.each { |m| run_mode(m) }
