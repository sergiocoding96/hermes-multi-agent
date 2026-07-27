-- forensic-audit.sql — capture every share_scope write without modifying behavior.
--
-- Purpose: catch any future re-emergence of bulk share_scope promotion. The
-- original culprit was a cron job from Sprint 3 (2026-05-12) that wrote
-- directly to SQLite, bypassing the daemon's HTTP API and namespace filter.
-- Disabled 2026-05-17 — see memos-setup/learnings/2026-05-17-v2-only-bge-shares.md.
--
-- Idempotent: safe to re-run. Down-script is `forensic-audit.down.sql`.

CREATE TABLE IF NOT EXISTS share_scope_audit (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_ms            INTEGER NOT NULL,
  table_name       TEXT    NOT NULL,
  row_id           TEXT    NOT NULL,
  operation        TEXT    NOT NULL,
  old_scope        TEXT,
  new_scope        TEXT,
  owner_profile_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_ssa_ts        ON share_scope_audit(ts_ms DESC);
CREATE INDEX IF NOT EXISTS idx_ssa_table_row ON share_scope_audit(table_name, row_id);

-- traces
DROP TRIGGER IF EXISTS share_scope_audit_traces_ins;
CREATE TRIGGER share_scope_audit_traces_ins
AFTER INSERT ON traces
BEGIN
  INSERT INTO share_scope_audit (ts_ms, table_name, row_id, operation, old_scope, new_scope, owner_profile_id)
  VALUES (CAST((julianday('now')-2440587.5)*86400000 AS INTEGER), 'traces', NEW.id, 'insert', NULL, NEW.share_scope, NEW.owner_profile_id);
END;

DROP TRIGGER IF EXISTS share_scope_audit_traces_upd;
CREATE TRIGGER share_scope_audit_traces_upd
AFTER UPDATE OF share_scope ON traces
WHEN COALESCE(NEW.share_scope,'__null__') != COALESCE(OLD.share_scope,'__null__')
BEGIN
  INSERT INTO share_scope_audit (ts_ms, table_name, row_id, operation, old_scope, new_scope, owner_profile_id)
  VALUES (CAST((julianday('now')-2440587.5)*86400000 AS INTEGER), 'traces', NEW.id, 'update', OLD.share_scope, NEW.share_scope, NEW.owner_profile_id);
END;

-- policies
DROP TRIGGER IF EXISTS share_scope_audit_policies_ins;
CREATE TRIGGER share_scope_audit_policies_ins
AFTER INSERT ON policies
BEGIN
  INSERT INTO share_scope_audit (ts_ms, table_name, row_id, operation, old_scope, new_scope, owner_profile_id)
  VALUES (CAST((julianday('now')-2440587.5)*86400000 AS INTEGER), 'policies', NEW.id, 'insert', NULL, NEW.share_scope, NEW.owner_profile_id);
END;

DROP TRIGGER IF EXISTS share_scope_audit_policies_upd;
CREATE TRIGGER share_scope_audit_policies_upd
AFTER UPDATE OF share_scope ON policies
WHEN COALESCE(NEW.share_scope,'__null__') != COALESCE(OLD.share_scope,'__null__')
BEGIN
  INSERT INTO share_scope_audit (ts_ms, table_name, row_id, operation, old_scope, new_scope, owner_profile_id)
  VALUES (CAST((julianday('now')-2440587.5)*86400000 AS INTEGER), 'policies', NEW.id, 'update', OLD.share_scope, NEW.share_scope, NEW.owner_profile_id);
END;

-- episodes
DROP TRIGGER IF EXISTS share_scope_audit_episodes_ins;
CREATE TRIGGER share_scope_audit_episodes_ins
AFTER INSERT ON episodes
BEGIN
  INSERT INTO share_scope_audit (ts_ms, table_name, row_id, operation, old_scope, new_scope, owner_profile_id)
  VALUES (CAST((julianday('now')-2440587.5)*86400000 AS INTEGER), 'episodes', NEW.id, 'insert', NULL, NEW.share_scope, NEW.owner_profile_id);
END;

DROP TRIGGER IF EXISTS share_scope_audit_episodes_upd;
CREATE TRIGGER share_scope_audit_episodes_upd
AFTER UPDATE OF share_scope ON episodes
WHEN COALESCE(NEW.share_scope,'__null__') != COALESCE(OLD.share_scope,'__null__')
BEGIN
  INSERT INTO share_scope_audit (ts_ms, table_name, row_id, operation, old_scope, new_scope, owner_profile_id)
  VALUES (CAST((julianday('now')-2440587.5)*86400000 AS INTEGER), 'episodes', NEW.id, 'update', OLD.share_scope, NEW.share_scope, NEW.owner_profile_id);
END;
