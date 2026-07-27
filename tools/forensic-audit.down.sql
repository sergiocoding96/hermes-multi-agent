-- forensic-audit.down.sql — remove the share_scope audit instrumentation
-- installed by `forensic-audit.sql`. Idempotent.

DROP TRIGGER IF EXISTS share_scope_audit_traces_ins;
DROP TRIGGER IF EXISTS share_scope_audit_traces_upd;
DROP TRIGGER IF EXISTS share_scope_audit_policies_ins;
DROP TRIGGER IF EXISTS share_scope_audit_policies_upd;
DROP TRIGGER IF EXISTS share_scope_audit_episodes_ins;
DROP TRIGGER IF EXISTS share_scope_audit_episodes_upd;
DROP INDEX  IF EXISTS idx_ssa_ts;
DROP INDEX  IF EXISTS idx_ssa_table_row;
DROP TABLE  IF EXISTS share_scope_audit;
