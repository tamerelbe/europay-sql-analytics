-- =====================================================================
-- 09_referral_network.sql
-- Business question: How far do referral chains spread, and who are our
--                    most influential referrers (direct + indirect)?
-- Output: top 10 referrers by the size of the network they started,
--         split into direct and indirect referrals, with chain depth.
-- Techniques: RECURSIVE CTE to walk a tree of unknown depth.
-- =====================================================================

WITH RECURSIVE referral_tree AS (
    -- anchor: every customer who referred at least one person is a root
    SELECT
        r.customer_id      AS root_referrer,
        r.customer_id      AS customer_id,
        0                  AS depth
    FROM customers r
    WHERE EXISTS (SELECT 1 FROM customers c WHERE c.referred_by = r.customer_id)

    UNION ALL

    -- step: add the people referred by anyone already in the tree
    SELECT
        t.root_referrer,
        c.customer_id,
        t.depth + 1
    FROM referral_tree t
    JOIN customers c ON c.referred_by = t.customer_id
    WHERE t.depth < 10                                   -- safety stop
),

network AS (
    SELECT
        root_referrer,
        COUNT(*) FILTER (WHERE depth = 1)  AS direct_referrals,
        COUNT(*) FILTER (WHERE depth >= 2) AS indirect_referrals,
        MAX(depth)                         AS deepest_level
    FROM referral_tree
    GROUP BY 1
)

SELECT
    n.root_referrer                                AS customer_id,
    c.country,
    n.direct_referrals,
    n.indirect_referrals,
    n.direct_referrals + n.indirect_referrals      AS total_network,
    n.deepest_level
FROM network n
JOIN customers c ON c.customer_id = n.root_referrer
ORDER BY total_network DESC, direct_referrals DESC, customer_id  -- id breaks ties so output is stable
LIMIT 10;
