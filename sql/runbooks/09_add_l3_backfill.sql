-- Runbook 09, part 2: run after T has passed, with the same {{L3}} and {{T}} as 09_add_l3.sql.

-- Step 2: after T, fill the past from the source with the same GROUP BY.
INSERT INTO gcl.{{L3}}
SELECT toStartOfMinute(Timestamp) AS Minute, LogId, SeverityText, count() AS Cnt
FROM gcl.gcl_logs_v1
WHERE PublishTime < toDateTime64('{{T}}', 3, 'UTC')
GROUP BY Minute, LogId, SeverityText;

-- Step 3: the totals match the source for a closed range.
SELECT (SELECT sum(Cnt) FROM gcl.{{L3}} WHERE Minute < '{{CHECK_TO}}'),
       (SELECT count() FROM gcl.gcl_logs_v1 WHERE Timestamp < '{{CHECK_TO}}');
