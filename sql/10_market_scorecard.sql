-- =====================================================================
-- 10_market_scorecard.sql
-- Business question: Which market should EuroPay prioritise for
--                    investment next quarter?
-- Output: one row per country with five metrics, each ranked, and a
--         composite score (average rank; lower = stronger market).
-- Techniques: combining several metric CTEs, RANK() per metric, a composite
--             score that averages the ranks, half-on-half growth comparison.
-- =====================================================================

WITH conversion AS (
    SELECT
        c.country,
        COUNT(DISTINCT e.customer_id) FILTER (WHERE e.event_type = 'first_transaction') * 1.0
            / COUNT(DISTINCT c.customer_id)                          AS signup_to_active
    FROM customers c
    LEFT JOIN onboarding_events e USING (customer_id)
    GROUP BY 1
),

activity AS (
    SELECT
        c.country,
        COUNT(DISTINCT t.customer_id) FILTER (WHERE t.txn_ts >= '2026-01-01')        AS mau_h1_2026,
        COUNT(DISTINCT t.customer_id) FILTER (WHERE t.txn_ts >= '2025-07-01'
                                               AND t.txn_ts <  '2026-01-01')         AS mau_h2_2025,
        SUM(t.fx_fee_eur + t.interchange_eur) FILTER (WHERE t.txn_ts >= '2026-01-01') AS txn_rev_h1_2026
    FROM customers c
    JOIN completed_txns t USING (customer_id)
    GROUP BY 1
),

retention AS (
    -- share of customers active in 2025-H2 who are still active in 2026-H1
    SELECT
        c.country,
        COUNT(DISTINCT h2.customer_id) FILTER (WHERE h1.customer_id IS NOT NULL) * 1.0
            / COUNT(DISTINCT h2.customer_id)                         AS h2_to_h1_retention
    FROM customers c
    JOIN (SELECT DISTINCT customer_id FROM completed_txns
          WHERE txn_ts >= '2025-07-01' AND txn_ts < '2026-01-01') h2 USING (customer_id)
    LEFT JOIN (SELECT DISTINCT customer_id FROM completed_txns
               WHERE txn_ts >= '2026-01-01') h1 USING (customer_id)
    GROUP BY 1
),

premium_mix AS (
    SELECT c.country, AVG(CASE WHEN ph.plan <> 'standard' THEN 1.0 ELSE 0 END) AS paid_plan_share
    FROM customers c
    JOIN plan_history ph USING (customer_id)
    WHERE ph.valid_to IS NULL
    GROUP BY 1
),

metrics AS (
    SELECT
        a.country,
        ROUND(100 * cv.signup_to_active, 1)                          AS signup_to_active_pct,
        ROUND(100 * r.h2_to_h1_retention, 1)                         AS retention_pct,
        ROUND(100.0 * (a.mau_h1_2026 * 1.0 / a.mau_h2_2025 - 1), 1)  AS active_user_growth_pct,
        ROUND(a.txn_rev_h1_2026 / a.mau_h1_2026, 2)                  AS txn_revenue_per_user_eur,
        ROUND(100 * pm.paid_plan_share, 1)                           AS paid_plan_pct
    FROM activity a
    JOIN conversion cv  USING (country)
    JOIN retention r    USING (country)
    JOIN premium_mix pm USING (country)
)

SELECT
    *,
    ROUND((  RANK() OVER (ORDER BY signup_to_active_pct      DESC)
           + RANK() OVER (ORDER BY retention_pct             DESC)
           + RANK() OVER (ORDER BY active_user_growth_pct    DESC)
           + RANK() OVER (ORDER BY txn_revenue_per_user_eur  DESC)
           + RANK() OVER (ORDER BY paid_plan_pct             DESC)) / 5.0, 1) AS composite_rank
FROM metrics
ORDER BY composite_rank;
