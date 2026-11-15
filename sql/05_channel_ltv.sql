-- =====================================================================
-- 05_channel_ltv.sql
-- Business question: Which acquisition channel brings the most valuable
--                    customers, measured by revenue in their first 6 months?
-- Output: 6-month revenue per activated customer by channel and country.
-- Techniques: revenue attribution across three sources, time-bounded
--             windows per customer, GROUPING SETS for two cuts in one query.
-- =====================================================================

WITH activated AS (
    SELECT customer_id, MIN(txn_ts) AS first_txn_ts
    FROM completed_txns
    GROUP BY 1
    -- only customers with a full 6 months of observation
    HAVING MIN(txn_ts) < TIMESTAMP '2026-01-01'
),

txn_revenue AS (
    SELECT a.customer_id, SUM(t.fx_fee_eur + t.interchange_eur) AS rev
    FROM activated a
    JOIN completed_txns t
      ON t.customer_id = a.customer_id
     AND t.txn_ts < a.first_txn_ts + INTERVAL 6 MONTH
    GROUP BY 1
),

sub_revenue AS (
    -- months active in first 6 months x fee of plan held in that month
    SELECT acm.customer_id, SUM(pf.monthly_fee_eur) AS rev
    FROM (
        SELECT DISTINCT t.customer_id, date_trunc('month', t.txn_ts) AS month
        FROM completed_txns t
        JOIN activated a USING (customer_id)
        WHERE t.txn_ts < a.first_txn_ts + INTERVAL 6 MONTH
    ) acm
    JOIN plan_history ph
      ON ph.customer_id = acm.customer_id
     AND ph.valid_from <= acm.month + INTERVAL 1 MONTH
     AND (ph.valid_to IS NULL OR ph.valid_to > acm.month + INTERVAL 1 MONTH)
    JOIN plan_fees pf ON pf.plan = ph.plan
    GROUP BY 1
),

customer_value AS (
    SELECT
        c.customer_id,
        c.acquisition_channel,
        c.country,
        COALESCE(tr.rev, 0) + COALESCE(sr.rev, 0) AS revenue_6m_eur
    FROM activated a
    JOIN customers c USING (customer_id)
    LEFT JOIN txn_revenue tr USING (customer_id)
    LEFT JOIN sub_revenue sr USING (customer_id)
)

SELECT
    CASE WHEN GROUPING(acquisition_channel) = 0 THEN 'channel' ELSE 'country' END AS cut,
    COALESCE(acquisition_channel, country)                       AS value,
    COUNT(*)                                                     AS activated_customers,
    ROUND(AVG(revenue_6m_eur), 2)                                AS avg_revenue_6m_eur,
    ROUND(MEDIAN(revenue_6m_eur), 2)                             AS median_revenue_6m_eur,
    CAST(ROUND(SUM(revenue_6m_eur), 0) AS BIGINT)                AS total_revenue_6m_eur
FROM customer_value
GROUP BY GROUPING SETS ((acquisition_channel), (country))
ORDER BY cut, avg_revenue_6m_eur DESC;
