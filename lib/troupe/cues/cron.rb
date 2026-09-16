# frozen_string_literal: true

module Troupe
  # 轻量 5 字段 cron（分 时 日 月 周）：支持 * , - / 与英文缩写（jan/sun…）。
  # 只负责计算 next 触发时刻（本地时区）；标准 cron 的 dom/dow 受限取或语义。
  module Cron
    MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].each_with_index.to_h { |n, i| [n, i + 1] }
    DOWS = %w[sun mon tue wed thu fri sat].each_with_index.to_h
    SPECS = { min: [0, 59], hour: [0, 23], dom: [1, 31], month: [1, 12], dow: [0, 7] }.freeze

    class << self
      # 返回严格晚于 from 的下一次触发时刻（Time）
      def next_after(expr, from)
        sets = parse!(expr)
        t = Time.at((from.to_i / 60 + 1) * 60) # 提升到下一分钟边界
        limit = 366 * 24 * 60 * 4 # 最多扫 4 年
        limit.times do
          return t if matches?(sets, t)

          t = advance(sets, t)
        end
        raise ArgumentError, "cron #{expr.inspect} 在 4 年内不存在下一次触发时间"
      end

      def parse!(expr)
        fields = expr.to_s.strip.split(/\s+/)
        raise ArgumentError, "cron 需要 5 个字段（分 时 日 月 周）：#{expr.inspect}" unless fields.size == 5

        keys = %i[min hour dom month dow]
        keys.zip(fields).to_h { |k, f| [k, parse_field(k, f)] }
      end

      def matches?(sets, t)
        return false unless sets[:month].include?(t.month)
        return false unless sets[:min].include?(t.min) && sets[:hour].include?(t.hour)

        dom_ok = sets[:dom].include?(t.day)
        dow_ok = sets[:dow].include?(t.wday)
        dom_restricted = sets[:dom] != full(:dom)
        dow_restricted = sets[:dow] != full(:dow)
        if dom_restricted && dow_restricted
          dom_ok || dow_ok
        else
          dom_ok && dow_ok
        end
      end

      private

      def full(key)
        lo, hi = SPECS[key]
        (lo..hi).to_a
      end

      def parse_field(key, field)
        lo, hi = SPECS[key]
        vals = field.split(",").flat_map do |part|
          range, step_s = part.split("/", 2)
          step = step_s && Integer(step_s, 10)
          raise ArgumentError, "cron 步长不能为 0：#{field.inspect}" if step == 0

          base =
            if range == "*"
              (lo..hi)
            elsif range.include?("-")
              a, b = range.split("-", 2)
              (value(key, a)..value(key, b))
            else
              v = value(key, range)
              step ? (v..hi) : (v..v) # "N/step" = N..max/step（vixie 语义）
            end
          unless lo <= base.first && base.last <= hi
            raise ArgumentError, "cron 字段越界：#{field.inspect}（#{key} 允许 #{lo}-#{hi}）"
          end

          base.step(step || 1).to_a
        end
        vals = vals.uniq
        raise ArgumentError, "cron 字段为空：#{field.inspect}" if vals.empty?

        vals.map! { |v| key == :dow && v == 7 ? 0 : v }
        vals.sort
      end

      def value(key, tok)
        case key
        when :month
          MONTHS[tok.downcase[0, 3]] || Integer(tok, 10)
        when :dow
          DOWS[tok.downcase[0, 3]] || Integer(tok, 10)
        else
          Integer(tok, 10)
        end
      rescue ArgumentError
        raise ArgumentError, "cron 无法解析字段值 #{tok.inspect}（#{key}）"
      end

      # 逐级跳跃：月 → 日 → 时 → 分（Time.new 对越界字段自动归一，DST 由时区处理）
      def advance(sets, t)
        off = t.utc_offset
        unless sets[:month].include?(t.month)
          return Time.new(t.year + (t.month == 12 ? 1 : 0), t.month == 12 ? 1 : t.month + 1, 1, 0, 0, 0, off)
        end
        unless day_matches?(sets, t)
          return Time.new(t.year, t.month, t.day, 24, 0, 0, off) # 次日 00:00
        end
        unless sets[:hour].include?(t.hour)
          return Time.new(t.year, t.month, t.day, t.hour + 1, 0, 0, off)
        end
        Time.new(t.year, t.month, t.day, t.hour, t.min + 1, 0, off)
      end

      def day_matches?(sets, t)
        dom_restricted = sets[:dom] != full(:dom)
        dow_restricted = sets[:dow] != full(:dow)
        if dom_restricted && dow_restricted
          sets[:dom].include?(t.day) || sets[:dow].include?(t.wday)
        else
          sets[:dom].include?(t.day) && sets[:dow].include?(t.wday)
        end
      end
    end
  end
end
