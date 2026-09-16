# frozen_string_literal: true

require "fileutils"
require_relative "prop_store"
require_relative "../errors"

module Troupe
  # SqlitePropStore：可选适配器（需要 sqlite3 gem；对标 Troupe.js 的 node:sqlite）。
  # CAS 以单条 UPDATE 实现（Provider 合同，DESIGN §7.2）。进程级持久。
  # 未安装 gem 时给出明确指引，不影响默认 PStore 路径。
  class SqlitePropStore < PropStore
    def initialize(path, ownership: true)
      begin
        require "sqlite3"
      rescue LoadError
        raise ConfigError, "SqlitePropStore 需要 sqlite3 gem：gem install sqlite3（或使用默认 PStorePropStore）"
      end
      FileUtils.mkdir_p(dir) unless dir.empty?
      @mutex = Mutex.new
      @db = ::SQLite3::Database.new(path)
      @db.results_as_hash = false
      @db.execute("PRAGMA journal_mode = WAL")
      @db.execute("PRAGMA synchronous = NORMAL")
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS troupe_props (
          k TEXT PRIMARY KEY,
          props TEXT NOT NULL,
          revision INTEGER NOT NULL,
          schema_version INTEGER NOT NULL,
          fence INTEGER NOT NULL DEFAULT 0
        )
      SQL
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS troupe_ownership (
          k TEXT PRIMARY KEY,
          owner TEXT NOT NULL,
          epoch INTEGER NOT NULL,
          lease_until INTEGER NOT NULL
        )
      SQL
      @supports_ownership = ownership
    end

    def ownership_enabled?
      @supports_ownership
    end

    def read(ns, role_id, stage_name)
      k = PropStore.key(ns, role_id, stage_name)
      @mutex.synchronize do
        row = @db.execute("SELECT props, revision, schema_version, fence FROM troupe_props WHERE k = ?", [k]).first
        row && StoredProps.new(props: JSON.parse(row[0]), revision: row[1], schema_version: row[2], fence: row[3])
      end
    end

    def create(ns, role_id, stage_name, props, schema_version:, fencing_token: 0)
      k = PropStore.key(ns, role_id, stage_name)
      json = JSON.generate(Codec.normalize(props, "$", {}))
      @mutex.synchronize do
        begin
          @db.execute("INSERT INTO troupe_props (k, props, revision, schema_version, fence) VALUES (?, ?, 1, ?, ?)",
                      [k, json, schema_version, fencing_token])
        rescue ::SQLite3::ConstraintException
          raise ConflictError, "Props 记录已存在：#{role_id}/#{stage_name}"
        end
        StoredProps.new(props: JSON.parse(json), revision: 1, schema_version: schema_version, fence: fencing_token)
      end
    end

    def write(ns, role_id, stage_name, props, expected_revision:, schema_version:, fencing_token: 0)
      k = PropStore.key(ns, role_id, stage_name)
      json = JSON.generate(Codec.normalize(props, "$", {}))
      @mutex.synchronize do
        changes = @db.execute(
          "UPDATE troupe_props SET props = ?, revision = revision + 1, schema_version = ?, " \
          "fence = CASE WHEN ? > fence THEN ? ELSE fence END " \
          "WHERE k = ? AND revision = ? AND ? >= fence",
          [json, schema_version, fencing_token, fencing_token, k, expected_revision, fencing_token]
        )
        if changes.empty? || @db.changes.zero?
          row = @db.execute("SELECT revision, fence FROM troupe_props WHERE k = ?", [k]).first
          raise ConflictError, "Props 记录不存在：#{role_id}/#{stage_name}" unless row
          if row[1] > fencing_token
            raise ConflictError, "fencing token 过期：token=#{fencing_token} < fence=#{row[1]}（DESIGN §6.5）"
          end

          raise ConflictError, "revision CAS 失败：expected=#{expected_revision} actual=#{row[0]}（#{role_id}/#{stage_name}）"
        end
        row = @db.execute("SELECT props, revision, schema_version, fence FROM troupe_props WHERE k = ?", [k]).first
        StoredProps.new(props: JSON.parse(row[0]), revision: row[1], schema_version: row[2], fence: row[3])
      end
    end

    def delete(ns, role_id, stage_name)
      k = PropStore.key(ns, role_id, stage_name)
      @mutex.synchronize do
        @db.execute("DELETE FROM troupe_props WHERE k = ?", [k])
        @db.execute("DELETE FROM troupe_ownership WHERE k = ?", [k])
      end
      nil
    end

    # ---- 所有权（与 Memory/PStore 同一合同） ----

    def acquire_ownership(ns, role_id, name, owner:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      @mutex.synchronize do
        row = @db.execute("SELECT owner, epoch, lease_until FROM troupe_ownership WHERE k = ?", [k]).first
        if row.nil? || row[2] <= now || row[0] == owner
          epoch = row.nil? ? 1 : (row[0] == owner ? row[1] : row[1] + 1)
          @db.execute(
            "INSERT INTO troupe_ownership (k, owner, epoch, lease_until) VALUES (?, ?, ?, ?) " \
            "ON CONFLICT(k) DO UPDATE SET owner = excluded.owner, epoch = excluded.epoch, lease_until = excluded.lease_until",
            [k, owner, epoch, now + lease_ms]
          )
          # 接管（epoch 前进）即前移 Props fence：旧持有者的后续写入被拒（DESIGN §6.5）
          if epoch > 1
            @db.execute("UPDATE troupe_props SET fence = ? WHERE k = ? AND fence < ?", [epoch, k, epoch])
          end
          OwnershipRecord.new(owner: owner, epoch: epoch, lease_until: now + lease_ms)
        end
      end
    end

    def renew_ownership(ns, role_id, name, owner:, expected_epoch:, lease_ms:)
      k = PropStore.key(ns, role_id, name)
      now = Util.now_ms
      @mutex.synchronize do
        @db.execute("UPDATE troupe_ownership SET lease_until = ? WHERE k = ? AND owner = ? AND epoch = ?",
                    [now + lease_ms, k, owner, expected_epoch])
        @db.changes.positive?
      end
    end

    def release_ownership(ns, role_id, name, owner:, expected_epoch:)
      k = PropStore.key(ns, role_id, name)
      @mutex.synchronize do
        # 释放但保留 epoch 墓碑：下次接管 epoch 单调递增（DESIGN §6.5）
        @db.execute("UPDATE troupe_ownership SET lease_until = 0 WHERE k = ? AND owner = ? AND epoch = ?",
                    [k, owner, expected_epoch])
      end
      nil
    end

    def close
      @mutex.synchronize { @db.close rescue nil }
    end
  end
end
