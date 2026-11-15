-- =====================================================================
-- 01_monthly_kpis.sql
-- Business question: How is EuroPay growing month over month?
-- Output: one row per month with active users, volume, revenue and growth.
-- Techniques: CTEs, date_trunc, LAG window function, generate_series for
--             subscription revenue from a slowly changing dimension.
-- =====================================================================

WITH months AS (
    SELECT CAST(m AS DATE) AS month
    FROM generate_series(DATE '2025-01-01', DATE '2026-06-01', INTERVAL 1 MONTH) AS t(m)
),

txn_month AS (
    SELECT
        date_trunc('month', txn_ts)::DATE            AS month,
        COUNT(DISTINCT customer_id)                  AS monthly_active_users,
        COUNT(*)                                     AS transactions,
        SUM(amount_eur)                              AS volume_eur,
        SUM(fx_fee_eur)                              AS fx_revenue_eur,
        SUM(interchange_eur)                         AS interchange_revenue_eur
    FROM completed_txns
    GROUP BY 1
),

-- Subscription revenue: a customer pays the fee of the plan they held
-- at the start of each month in which they were active.
active_customer_months AS (
    SELECT DISTINCT customer_id, date_trunc('month', txn_ts)::DATE AS month
    FROM completed_txns
),
subscription_month AS (
    SELECT
        acm.month,
        SUM(pf.monthly_fee_eur) AS subscription_revenue_eur
    FROM active_customer_months acm
    JOIN plan_history ph
      ON ph.customer_id = acm.customer_id
     AND ph.valid_from <= acm.month + INTERVAL 1 MONTH
     AND (ph.valid_to IS NULL OR ph.valid_to > acm.month + INTERVAL 1 MONTH)
    JOIN plan_fees pf ON pf.plan = ph.plan
    GROUP BY 1
),

kpis AS (
    SELECT
        m.month,
        COALESCE(t.monthly_active_users, 0)                          AS monthly_active_users,
        COALESCE(t.transactions, 0)                                  AS transactions,
        CAST(ROUND(COALESCE(t.volume_eur, 0), 0) AS BIGINT)        AS volume_eur,
        ROUND(COALESCE(t.fx_revenue_eur, 0)
            + COALESCE(t.interchange_revenue_eur, 0)
            + COALESCE(s.subscription_revenue_eur, 0), 0)            AS total_revenue_eur
    FROM months m
    LEFT JOIN txn_month t          USING (month)
    LEFT JOIN subscription_month s USING (month)
)

SELECT
    month,
    monthly_active_users,
    transactions,
    volume_eur,
    total_revenue_eur,
    ROUND(total_revenue_eur / NULLIF(monthly_active_users, 0), 2)    AS revenue_per_mau_eur,
    ROUND(100.0 * (monthly_active_users
        / NULLIF(LAG(monthly_active_users) OVER (ORDER BY month), 0) - 1), 1) AS mau_growth_pct,
    ROUND(100.0 * (total_revenue_eur
        / NULLIF(LAG(total_revenue_eur) OVER (ORDER BY month), 0) - 1), 1)    AS revenue_growth_pct
FROM kpis
ORDER BY month;
