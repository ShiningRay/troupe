# frozen_string_literal: true

require "logger"

module Troupe
  module Log
    module_function

    def logger
      @logger ||= begin
        level_name = (ENV["TROUPE_LOG"] || "info").upcase
        level = Logger.const_defined?(level_name) ? Logger.const_get(level_name) : Logger::INFO
        l = Logger.new($stderr)
        l.level = level
        l.formatter = ->(_sev, _time, _prog, msg) { "[troupe] #{msg}\n" }
        l
      end
    end

    def debug(msg = nil, &blk)
      logger.debug(msg, &blk)
    end

    def info(msg = nil, &blk)
      logger.info(msg, &blk)
    end

    def warn(msg = nil, &blk)
      logger.warn(msg, &blk)
    end

    def error(msg = nil, &blk)
      logger.error(msg, &blk)
    end
  end
end
