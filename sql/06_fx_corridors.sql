-- =====================================================================
-- 06_fx_corridors.sql
-- Business question: Which currency corridors drive FX revenue, and how
--                    concentrated is that revenue?
-- Output: corridors ranked by FX revenue with cumulative share (Pareto).
-- Techniques: running totals with SUM() OVER (ORDER BY ...), share of
--             total, effective take rate, RANK.
-- =====================================================================

WITH corridors AS (
    SELECT
        fx_pair,
        COUNT(*)                      AS fx_transactions,
        COUNT(DISTINCT customer_id)   AS customers,
        SUM(amount_eur)               AS fx_volume_eur,
        SUM(fx_fee_eur)               AS fx_revenue_eur
    FROM completed_txns
    WHERE is_fx
    GROUP BY 1
)

SELECT
    RANK() OVER (ORDER BY fx_revenue_eur DESC)                       AS rank,
    fx_pair,
    fx_transactions,
    customers,
    CAST(ROUND(fx_volume_eur, 0) AS BIGINT)                          AS fx_volume_eur,
    CAST(ROUND(fx_revenue_eur, 0) AS BIGINT)                         AS fx_revenue_eur,
    ROUND(100.0 * fx_revenue_eur / fx_volume_eur, 3)                 AS take_rate_pct,
    ROUND(100.0 * fx_revenue_eur / SUM(fx_revenue_eur) OVER (), 1)   AS pct_of_fx_revenue,
    ROUND(100.0 * SUM(fx_revenue_eur) OVER (ORDER BY fx_revenue_eur DESC
                                            ROWS UNBOUNDED PRECEDING)
                / SUM(fx_revenue_eur) OVER (), 1)                    AS cumulative_pct
FROM corridors
ORDER BY rank;
