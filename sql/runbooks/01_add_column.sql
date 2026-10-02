-- Runbook 01: add a derived column without stopping ingestion.
-- Order matters: the target column must exist before the MV starts producing it.
-- Verified under load: 0 failed inserts, each insert block carries exactly one parser version.

-- Step 1: add the column to the MV target. Existing rows get the default value.
ALTER TABLE gcl.gcl_logs_v1
    ADD COLUMN IF NOT EXISTS K8sNamespace LowCardinality(String) AFTER ServiceName;

-- Step 2: replace the whole MV SELECT (MODIFY QUERY needs the full text; keep it in Git).
--   Paste the body of sql/30_logs_v1_mv.sql (from WITH to FROM) and add the new expression, e.g.
--     if(res_type = 'k8s_container', res_labels['namespace_name'], '') AS K8sNamespace,
--   Bump ParserVersion so the switch point is visible in the data.
ALTER TABLE gcl.gcl_logs_v1_mv MODIFY QUERY
WITH
    -- ... body of sql/30_logs_v1_mv.sql ...
SELECT
    -- ... existing columns ...
FROM gcl.gcl_landing_v1;

-- Step 3: confirm the switch.
SELECT ParserVersion, min(InsertedAt), max(InsertedAt), count()
FROM gcl.gcl_logs_v1
WHERE InsertedAt > now() - INTERVAL 15 MINUTE
GROUP BY ParserVersion ORDER BY ParserVersion;
-- Past rows keep the default. To fill them, rebuild partitions from L0 (runbook 02) while L0 still holds them.
