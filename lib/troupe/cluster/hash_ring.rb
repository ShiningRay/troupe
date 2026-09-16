# frozen_string_literal: true

require_relative "xxh32"

module Troupe
  # 一致性哈希环（Playbill 的候选归属，DESIGN §6.3）：
  # xxh32 + 每 Stage 160 虚拟节点；无注册、无目录查询、无缓存失效。
  # HashRing 只回答"候选归谁"，是否真正拥有由所有权契约决定（DESIGN §6.5）。
  class HashRing
    DEFAULT_VNODES = 160

    attr_reader :vnodes

    def initialize(vnodes = DEFAULT_VNODES)
      @vnodes = vnodes
      @ring = {}
      @keys = []
      @nodes = []
    end

    def add_node(node)
      return self if @nodes.include?(node)

      @nodes << node
      @vnodes.times do |i|
        @ring[Xxh32.digest("#{node}##{i}")] = node
      end
      rebuild
      self
    end

    def remove_node(node)
      return self unless @nodes.delete(node)

      @ring.delete_if { |_, n| n == node }
      rebuild
      self
    end

    def nodes
      @nodes.dup
    end

    def size
      @keys.size
    end

    def get_node(key)
      return nil if @keys.empty?

      h = Xxh32.digest(key.to_s)
      idx = @keys.bsearch_index { |k| k >= h } || 0
      @ring[@keys[idx]]
    end

    # 虚拟节点分布（CLI `ring`：均衡度观测）
    def distribution
      @ring.values.tally
    end

    private

    def rebuild
      @keys = @ring.keys.sort
    end
  end
end
