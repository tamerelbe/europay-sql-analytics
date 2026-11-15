-- =====================================================================
-- 03_cohort_retention.sql
-- Business question: Of the customers who started in a given month,
--                    what share are still active 1, 3, 6 and 12 months later?
-- Output: classic cohort retention table.
-- Techniques: cohort assignment, month offsets with date_diff,
--             conditional COUNT DISTINCT, NULL for months not yet observable.
-- =====================================================================

WITH first_activity AS (
    SELECT customer_id, date_trunc('month', MIN(txn_ts))::DATE AS cohort_month
    FROM completed_txns
    GROUP BY 1
),

activity AS (
    SELECT DISTINCT
        t.customer_id,
        f.cohort_month,
        date_diff('month', f.cohort_month, date_trunc('month', t.txn_ts)::DATE) AS month_offset
    FROM completed_txns t
    JOIN first_activity f USING (customer_id)
),

cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size
    FROM first_activity
    GROUP BY 1
),

-- last complete month in the data: offsets beyond it cannot be measured yet
last_month AS (
    SELECT date_trunc('month', MAX(txn_ts))::DATE AS m FROM completed_txns
),

retention AS (
    SELECT
        a.cohort_month,
        s.cohort_size,
        COUNT(DISTINCT a.customer_id) FILTER (WHERE month_offset = 1)  AS m1,
        COUNT(DISTINCT a.customer_id) FILTER (WHERE month_offset = 3)  AS m3,
        COUNT(DISTINCT a.customer_id) FILTER (WHERE month_offset = 6)  AS m6,
        COUNT(DISTINCT a.customer_id) FILTER (WHERE month_offset = 12) AS m12
    FROM activity a
    JOIN cohort_sizes s USING (cohort_month)
    GROUP BY a.cohort_month, s.cohort_size
)

SELECT
    r.cohort_month,
    r.cohort_size,
    -- NULL (not 0) when the cohort is too young to measure that month
    CASE WHEN r.cohort_month + INTERVAL 1 MONTH  <= l.m THEN ROUND(100.0 * m1  / cohort_size, 1) END AS m1_pct,
    CASE WHEN r.cohort_month + INTERVAL 3 MONTH  <= l.m THEN ROUND(100.0 * m3  / cohort_size, 1) END AS m3_pct,
    CASE WHEN r.cohort_month + INTERVAL 6 MONTH  <= l.m THEN ROUND(100.0 * m6  / cohort_size, 1) END AS m6_pct,
    CASE WHEN r.cohort_month + INTERVAL 12 MONTH <= l.m THEN ROUND(100.0 * m12 / cohort_size, 1) END AS m12_pct
FROM retention r
CROSS JOIN last_month l
ORDER BY r.cohort_month;
