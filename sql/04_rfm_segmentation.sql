-- =====================================================================
-- 04_rfm_segmentation.sql
-- Business question: Which customers are our champions, and which are
--                    slipping away and worth a win-back campaign?
-- Output: segment sizes and value, using Recency-Frequency-Monetary scoring.
-- Techniques: NTILE quintiles, CASE-based segment rules, nested aggregation.
-- =====================================================================

WITH snapshot AS (
    SELECT MAX(txn_ts) AS as_of FROM completed_txns
),

rfm_raw AS (
    SELECT
        t.customer_id,
        date_diff('day', MAX(t.txn_ts), (SELECT as_of FROM snapshot)) AS recency_days,
        COUNT(*)                                                    AS frequency,
        SUM(t.amount_eur)                                           AS monetary_eur
    FROM completed_txns t
    GROUP BY 1
),

rfm_scored AS (
    SELECT
        *,
        6 - NTILE(5) OVER (ORDER BY recency_days, customer_id) AS r_score,   -- 5 = most recent
        NTILE(5) OVER (ORDER BY frequency, customer_id)    AS f_score,   -- 5 = most frequent
        NTILE(5) OVER (ORDER BY monetary_eur, customer_id) AS m_score    -- 5 = highest spend
    FROM rfm_raw
),

segmented AS (
    SELECT
        *,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN '1. Champions'
            WHEN r_score >= 3 AND f_score >= 3                  THEN '2. Loyal'
            WHEN r_score >= 4 AND f_score <= 2                  THEN '3. New / promising'
            WHEN r_score = 2  AND f_score >= 3                  THEN '4. At risk'
            WHEN r_score <= 2 AND f_score >= 4                  THEN '5. Cannot lose them'
            WHEN r_score = 1                                    THEN '7. Lost'
            ELSE                                                     '6. Need attention'
        END AS segment
    FROM rfm_scored
)

SELECT
    segment,
    COUNT(*)                                                      AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)            AS pct_customers,
    ROUND(AVG(recency_days), 0)                                   AS avg_recency_days,
    ROUND(AVG(frequency), 0)                                      AS avg_transactions,
    ROUND(AVG(monetary_eur), 0)                                   AS avg_spend_eur,
    ROUND(100.0 * SUM(monetary_eur) / SUM(SUM(monetary_eur)) OVER (), 1) AS pct_total_spend
FROM segmented
GROUP BY segment
ORDER BY segment;
