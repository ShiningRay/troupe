# frozen_string_literal: true

require "json"
require "date"
require "time"
require "bigdecimal"
require "set"

module Troupe
  # 序列化边界（DESIGN §6.1）：默认 JSON。
  # 本地调用默认也走同一编解码/复制边界——本地、远程、Rehearsal 三种模式数据行为一致。
  # 约定：Hash 键一律归一为字符串；Symbol 值 → String；Time/Date → ISO 8601；
  # BigInt 在 Ruby 原生支持（与 JS 不同，无精度问题）；循环引用、其他类型抛错并指引 DTO。
  module Codec
    module_function

    # 归一化并深拷贝：保证调用方/被调方互不共享可变结构
    def copy(value)
      return value if value.nil? || value == true || value == false || value.is_a?(Integer) || value.is_a?(Float)

      JSON.parse(encode(value))
    end

    def encode(value)
      JSON.generate(normalize(value, "$", {}))
    end

    def decode(str)
      JSON.parse(str)
    end

    def normalize(value, path, seen)
      case value
      when NilClass, TrueClass, FalseClass, Integer, Float, String
        value
      when Symbol then value.to_s
      when Time, DateTime then value.iso8601(6)
      when Date then value.iso8601
      when BigDecimal then value.to_s("F")
      when Array
        guard_cycle(value, path, seen) do
          value.each_with_index.map { |v, i| normalize(v, "#{path}[#{i}]", seen) }
        end
      when Hash
        guard_cycle(value, path, seen) do
          value.each_with_object({}) do |(k, v), h|
            h[normalize_key(k, path)] = normalize(v, "#{path}.#{k}", seen)
          end
        end
      else
        raise SerializationError,
              "无法序列化 #{value.class}（#{path}）：JSON 边界只支持 Hash/Array/标量；" \
              "Time/Date → ISO 字符串、Symbol → String。请改用可序列化 DTO（DESIGN §6.1）"
      end
    end

    # seen 以 object_id 标记在递归路径上：共享引用（DAG）放行，真正的环报错
    def guard_cycle(obj, path, seen)
      raise SerializationError, "循环引用（#{path}）：JSON 边界不支持，请改用可序列化 DTO" if seen.key?(obj.object_id)

      seen[obj.object_id] = true
      result = yield
      seen.delete(obj.object_id)
      result
    end

    def normalize_key(key, path)
      case key
      when String then key
      when Symbol then key.to_s
      when Integer then key.to_s
      else
        raise SerializationError, "Hash 键 #{key.class}（#{path}）无法序列化：只支持 String/Symbol/Integer 键"
      end
    end
  end
end
