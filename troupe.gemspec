# frozen_string_literal: true

require_relative "lib/troupe/version"

Gem::Specification.new do |s|
  s.name = "troupe"
  s.version = Troupe::VERSION
  s.summary = "Troupe.rb —— Virtual Actor 框架（Troupe.js 的 Ruby 版本）"
  s.description = "面向 Ruby 的 Virtual Actor 框架：永远存在的 Actor、Turn-based 严格串行、" \
                  "Props 持久化、一致性哈希集群、持久提醒。命名与语义对标 Troupe.js（Orleans/Orbit 思想）。"
  s.authors = ["shiningray"]
  s.homepage = "https://github.com/ShiningRay/troupe"
  s.license = "MIT"
  s.required_ruby_version = ">= 3.1"
  s.files = Dir["lib/**/*.rb"] + %w[bin/troupe README.md DESIGN_NOTES.md LICENSE]
  s.bindir = "bin"
  s.executables = ["troupe"]
  s.add_development_dependency "minitest", "~> 5.0"
  s.add_development_dependency "rake", "~> 13.0"
  # 运行时零 gem 依赖：PStore/TCPSocket/JSON 均为 stdlib；sqlite3 为可选适配器
end
