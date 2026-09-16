# frozen_string_literal: true

module Troupe
  # 纯 Ruby xxh32（零原生依赖，对标 Troupe.js 的纯 JS xxh32 实现同算法）
  module Xxh32
    P1 = 2_654_435_761
    P2 = 2_246_822_519
    P3 = 3_266_489_917
    P4 = 668_265_263
    P5 = 374_761_393
    M32 = 0xFFFF_FFFF

    module_function

    def digest(str, seed = 0)
      buf = str.to_s.b
      len = buf.bytesize
      i = 0
      if len >= 16
        v1 = (seed + P1 + P2) & M32
        v2 = (seed + P2) & M32
        v3 = seed & M32
        v4 = (seed - P1) & M32
        lanes = buf.unpack("V*")
        while i + 16 <= len
          v1 = round(v1, lanes[(i >> 2)])
          v2 = round(v2, lanes[(i >> 2) + 1])
          v3 = round(v3, lanes[(i >> 2) + 2])
          v4 = round(v4, lanes[(i >> 2) + 3])
          i += 16
        end
        acc = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & M32
      else
        acc = (seed + P5) & M32
      end
      acc = (acc + len) & M32
      while i + 4 <= len
        acc = (acc + buf.unpack1("V", offset: i) * P3) & M32
        acc = (rotl(acc, 17) * P4) & M32
        i += 4
      end
      while i < len
        acc = (acc + buf.getbyte(i) * P5) & M32
        acc = (rotl(acc, 11) * P1) & M32
        i += 1
      end
      avalanche(acc)
    end

    def round(acc, lane)
      acc = (acc + (lane * P2)) & M32
      acc = rotl(acc, 13)
      (acc * P1) & M32
    end

    def rotl(x, r)
      ((x << r) | (x >> (32 - r))) & M32
    end

    def avalanche(acc)
      acc ^= acc >> 15
      acc = (acc * P2) & M32
      acc ^= acc >> 13
      acc = (acc * P3) & M32
      acc ^ (acc >> 16)
    end
  end
end
