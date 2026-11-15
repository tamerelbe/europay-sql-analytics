-- =====================================================================
-- 07_churn_by_segment.sql
-- Business question: Who stops using EuroPay, and how quickly?
-- Definition: a customer has churned if they have had no completed
--             transaction for 60+ days before the end of the data.
-- Output: churn rate and median active lifetime by plan and channel.
-- Techniques: gaps between consecutive transactions with LEAD,
--             longest inactivity gap, churn flag, multi-dimension pivot.
-- =====================================================================

WITH bounds AS (
    SELECT MAX(txn_ts) AS as_of FROM completed_txns
),

per_customer AS (
    SELECT
        customer_id,
        MIN(txn_ts) AS first_txn_ts,
        MAX(txn_ts) AS last_txn_ts
    FROM completed_txns
    GROUP BY 1
),

-- current plan per customer
current_plan AS (
    SELECT customer_id, plan
    FROM plan_history
    WHERE valid_to IS NULL
),

-- longest gap between two consecutive transactions (a sign of disengagement)
gaps AS (
    SELECT
        customer_id,
        MAX(date_diff('day', txn_ts, next_ts)) AS longest_gap_days
    FROM (
        SELECT customer_id, txn_ts,
               LEAD(txn_ts) OVER (PARTITION BY customer_id ORDER BY txn_ts) AS next_ts
        FROM completed_txns
    )
    WHERE next_ts IS NOT NULL
    GROUP BY 1
),

flagged AS (
    SELECT
        p.customer_id,
        c.acquisition_channel,
        cp.plan,
        date_diff('day', p.first_txn_ts, p.last_txn_ts)                        AS active_days,
        date_diff('day', p.last_txn_ts, (SELECT as_of FROM bounds)) >= 60      AS churned,
        g.longest_gap_days
    FROM per_customer p
    JOIN customers c     USING (customer_id)
    JOIN current_plan cp USING (customer_id)
    LEFT JOIN gaps g     USING (customer_id)
    -- exclude customers too new to have been able to churn
    WHERE p.first_txn_ts < (SELECT as_of FROM bounds) - INTERVAL 60 DAY
)

SELECT
    plan,
    CASE WHEN GROUPING(acquisition_channel) = 1 THEN '(all channels)'
         ELSE acquisition_channel END                           AS acquisition_channel,
    COUNT(*)                                                    AS customers,
    ROUND(100.0 * AVG(CASE WHEN churned THEN 1 ELSE 0 END), 1)  AS churn_rate_pct,
    MEDIAN(active_days) FILTER (WHERE churned)                  AS median_days_before_churn,
    ROUND(AVG(longest_gap_days), 0)                             AS avg_longest_gap_days
FROM flagged
GROUP BY ROLLUP (plan, acquisition_channel)
HAVING plan IS NOT NULL
ORDER BY plan, GROUPING(acquisition_channel) DESC, acquisition_channel;
