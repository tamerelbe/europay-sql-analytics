-- =====================================================================
-- 08_fraud_velocity.sql
-- Business question: Which accounts show fraud-like behaviour that the
--                    risk team should review?
-- Rules (both must fire):
--   1. Velocity: 5+ card payments within any 10-minute window.
--   2. Size:     the window's spend is 5x+ the customer's typical
--                (median) transaction, measured on their history.
-- Output: one row per flagged customer, with the worst burst.
-- Techniques: RANGE window frames over time intervals, per-customer
--             baselines, QUALIFY to keep the top window per customer.
-- =====================================================================

WITH card_txns AS (
    SELECT customer_id, txn_id, txn_ts, amount_eur
    FROM completed_txns
    WHERE category NOT IN ('transfer', 'fx_exchange', 'atm')
),

baseline AS (
    SELECT customer_id, MEDIAN(amount_eur) AS typical_amount_eur
    FROM card_txns
    GROUP BY 1
),

windows AS (
    SELECT
        customer_id,
        txn_ts AS window_end,
        COUNT(*) OVER w        AS txns_in_10min,
        SUM(amount_eur) OVER w AS spend_in_10min
    FROM card_txns
    WINDOW w AS (
        PARTITION BY customer_id
        ORDER BY txn_ts
        RANGE BETWEEN INTERVAL 10 MINUTE PRECEDING AND CURRENT ROW
    )
),

flags AS (
    SELECT
        w.customer_id,
        w.window_end,
        w.txns_in_10min,
        ROUND(w.spend_in_10min, 2)                               AS spend_in_10min_eur,
        ROUND(b.typical_amount_eur, 2)                           AS typical_amount_eur,
        ROUND(w.spend_in_10min / w.txns_in_10min
              / b.typical_amount_eur, 1)                         AS size_vs_typical
    FROM windows w
    JOIN baseline b USING (customer_id)
    WHERE w.txns_in_10min >= 5
      AND w.spend_in_10min / w.txns_in_10min >= 5 * b.typical_amount_eur
    QUALIFY ROW_NUMBER() OVER (PARTITION BY w.customer_id
                               ORDER BY w.spend_in_10min DESC) = 1
)

SELECT
    f.customer_id,
    c.country,
    f.window_end AS burst_ended_at,
    f.txns_in_10min,
    f.spend_in_10min_eur,
    f.typical_amount_eur,
    f.size_vs_typical
FROM flags f
JOIN customers c USING (customer_id)
ORDER BY f.spend_in_10min_eur DESC;
