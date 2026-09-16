# frozen_string_literal: true

require_relative "troupe/version"
require_relative "troupe/util"
require_relative "troupe/errors"
require_relative "troupe/log"
require_relative "troupe/codec"
require_relative "troupe/call"
require_relative "troupe/repertoire"
require_relative "troupe/actor"
require_relative "troupe/agent"
require_relative "troupe/trace"
require_relative "troupe/show"
require_relative "troupe/props/prop_store"
require_relative "troupe/props/pstore_store"
require_relative "troupe/cluster/xxh32"
require_relative "troupe/cluster/hash_ring"
require_relative "troupe/cluster/roster"
require_relative "troupe/cluster/playbill"
require_relative "troupe/cluster/transport"
require_relative "troupe/cues/cron"
require_relative "troupe/cues/cue_store"
require_relative "troupe/cues/scheduler"
require_relative "troupe/stage_manager"
require_relative "troupe/config"
require_relative "troupe/director"
require_relative "troupe/troupe"

module Troupe
  # Rehearsal（排练，DESIGN §2 / PLAN M1）：测试集群。
  # 全内存存储、不启动传输与 Roster——本地/远程/Rehearsal 三种模式
  # 共享同一编解码/复制边界与调度语义，测试不掩盖部署差异。
  module Testing
    module_function

    def rehearsal(actors: nil, **opts)
      Troupe.form(actors: actors, **opts, rehearsal: true, transport: false)
    end
  end
end
