-- =====================================================================
-- 02_onboarding_funnel.sql
-- Business question: Where do new customers drop out of onboarding,
--                    and is any market performing worse than the rest?
-- Output: funnel conversion by country, step by step.
-- Techniques: conditional aggregation (FILTER), pivoting events into
--             columns, step-over-step conversion, median time to activate.
-- =====================================================================

WITH per_customer AS (
    SELECT
        c.customer_id,
        c.country,
        MIN(e.event_ts) FILTER (WHERE e.event_type = 'signup')            AS signup_ts,
        MIN(e.event_ts) FILTER (WHERE e.event_type = 'kyc_submitted')     AS kyc_submitted_ts,
        MIN(e.event_ts) FILTER (WHERE e.event_type = 'kyc_approved')      AS kyc_approved_ts,
        MIN(e.event_ts) FILTER (WHERE e.event_type = 'card_activated')    AS card_activated_ts,
        MIN(e.event_ts) FILTER (WHERE e.event_type = 'first_transaction') AS first_txn_ts
    FROM customers c
    JOIN onboarding_events e USING (customer_id)
    GROUP BY 1, 2
),

by_country AS (
    SELECT
        country,
        COUNT(*)                                AS signed_up,
        COUNT(kyc_submitted_ts)                 AS kyc_submitted,
        COUNT(kyc_approved_ts)                  AS kyc_approved,
        COUNT(card_activated_ts)                AS card_activated,
        COUNT(first_txn_ts)                     AS transacted,
        MEDIAN(date_diff('hour', signup_ts, first_txn_ts)) / 24.0 AS median_days_to_first_txn
    FROM per_customer
    GROUP BY ROLLUP (country)          -- adds an all-markets total row
)

SELECT
    COALESCE(country, 'ALL')                                         AS country,
    signed_up,
    ROUND(100.0 * kyc_submitted  / signed_up,      1)                AS pct_submit_kyc,
    ROUND(100.0 * kyc_approved   / kyc_submitted,  1)                AS pct_kyc_approved,
    ROUND(100.0 * card_activated / kyc_approved,   1)                AS pct_card_activated,
    ROUND(100.0 * transacted     / card_activated, 1)                AS pct_first_txn,
    ROUND(100.0 * transacted     / signed_up,      1)                AS overall_conversion_pct,
    ROUND(median_days_to_first_txn, 1)                               AS median_days_to_first_txn
FROM by_country
ORDER BY country = 'ALL', overall_conversion_pct DESC;
