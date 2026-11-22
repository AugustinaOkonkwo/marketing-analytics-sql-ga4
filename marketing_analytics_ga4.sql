/* =====================================================================
   MARKETING FUNNEL & CHANNEL ATTRIBUTION ANALYSIS
   ---------------------------------------------------------------------
   Author  : Tina Okonkwo
   Data    : bigquery-public-data.ga4_obfuscated_sample_ecommerce
             Google Merchandise Store, GA4 export, 1 Nov 2020 - 31 Jan 2021
   Engine  : Google BigQuery (GoogleSQL)

   BUSINESS QUESTIONS
   1. How much traffic, how many customers and how much revenue do we have?
   2. Where do users drop off in the purchase funnel, and does it differ by device?
   3. Which marketing channels drive revenue, and which drive quality traffic?
   4. How does channel credit change under first-touch, last-touch and
      linear attribution?
   5. Do users come back after their first visit? (monthly cohort retention)
   6. Who are our most valuable customers? (RFM segmentation)
   7. Which acquisition channels bring the most valuable customers?

   HOW TO RUN
   Run the whole file as one script in the BigQuery console. Steps 0a-0e
   build temporary tables that every analysis query reuses, so the public
   dataset is scanned only once. Each query's result appears as its own
   tab under "Execution details / Results".

   NOTE ON THE DATA
   Google obfuscates this dataset: some values show as '<Other>',
   '(data deleted)' or '(not set)'. They are kept and labelled
   ('Obfuscated', 'Unassigned') instead of being dropped, so totals
   reconcile across queries.
   ===================================================================== */


/* ---------------------------------------------------------------------
   0a. CHANNEL GROUPING
   Maps raw source / medium into marketing channels, similar to GA4's
   default channel grouping.
   --------------------------------------------------------------------- */
CREATE TEMP FUNCTION channel_group(src STRING, med STRING) AS (
  CASE
    WHEN src IS NULL AND med IS NULL                                   THEN 'Unassigned'
    WHEN LOWER(med) IN ('(data deleted)', '<other>')
      OR LOWER(src) IN ('(data deleted)', '<other>')                   THEN 'Obfuscated'
    WHEN src = '(direct)' AND LOWER(med) IN ('(none)', '(not set)')    THEN 'Direct'
    WHEN LOWER(med) = 'organic'                                        THEN 'Organic Search'
    WHEN REGEXP_CONTAINS(LOWER(med), r'^(cpc|ppc|paid.*)$')            THEN 'Paid Search'
    WHEN REGEXP_CONTAINS(LOWER(med), r'^(cpm|display|banner)$')        THEN 'Display'
    WHEN REGEXP_CONTAINS(LOWER(med), r'email')                         THEN 'Email'
    WHEN LOWER(med) = 'referral'                                       THEN 'Referral'
    ELSE 'Other'
  END
);


/* ---------------------------------------------------------------------
   0b. BASE EVENTS
   One row per event, with the nested event_params flattened into
   columns. This is the only step that reads the public dataset.
   --------------------------------------------------------------------- */
CREATE TEMP TABLE base_events AS
SELECT
  PARSE_DATE('%Y%m%d', event_date)                    AS event_date,
  TIMESTAMP_MICROS(event_timestamp)                   AS event_ts,
  event_name,
  user_pseudo_id,
  -- ga_session_id is only unique per user, so combine the two
  CONCAT(
    user_pseudo_id, '-',
    CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING)
  )                                                   AS session_key,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'source') AS session_source,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium') AS session_medium,
  (SELECT COALESCE(value.string_value, CAST(value.int_value AS STRING))
     FROM UNNEST(event_params) WHERE key = 'session_engaged')               AS session_engaged,
  traffic_source.source                               AS first_touch_source,   -- user-level acquisition
  traffic_source.medium                               AS first_touch_medium,
  DATE(TIMESTAMP_MICROS(user_first_touch_timestamp))  AS first_touch_date,
  device.category                                     AS device,
  geo.country                                         AS country,
  NULLIF(ecommerce.transaction_id, '(not set)')       AS transaction_id,
  ecommerce.purchase_revenue_in_usd                   AS revenue_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';


/* ---------------------------------------------------------------------
   0c. SESSIONS
   One row per session: its channel (taken from the first event that
   carries a source), engagement and which funnel steps it reached.
   --------------------------------------------------------------------- */
CREATE TEMP TABLE sessions AS
SELECT
  * EXCEPT (traffic),
  traffic.source                                  AS source,
  traffic.medium                                  AS medium,
  channel_group(traffic.source, traffic.medium)   AS channel
FROM (
  SELECT
    session_key,
    ANY_VALUE(user_pseudo_id)                     AS user_pseudo_id,
    ANY_VALUE(device)                             AS device,
    MIN(event_ts)                                 AS session_start_ts,
    ARRAY_AGG(
      IF(session_source IS NOT NULL,
         STRUCT(session_source AS source, session_medium AS medium),
         NULL)
      IGNORE NULLS ORDER BY event_ts LIMIT 1
    )[SAFE_OFFSET(0)]                             AS traffic,
    IFNULL(LOGICAL_OR(session_engaged = '1'), FALSE) AS is_engaged,
    LOGICAL_OR(event_name = 'view_item')          AS reached_view_item,
    LOGICAL_OR(event_name = 'add_to_cart')        AS reached_add_to_cart,
    LOGICAL_OR(event_name = 'begin_checkout')     AS reached_checkout,
    LOGICAL_OR(event_name = 'add_payment_info')   AS reached_payment,
    LOGICAL_OR(event_name = 'purchase')           AS reached_purchase
  FROM base_events
  WHERE session_key IS NOT NULL
  GROUP BY session_key
);


/* ---------------------------------------------------------------------
   0d. PURCHASES
   One row per order. Duplicate purchase events for the same
   transaction are collapsed so revenue is not double counted.
   --------------------------------------------------------------------- */
CREATE TEMP TABLE purchases AS
SELECT
  COALESCE(transaction_id,
           CONCAT(user_pseudo_id, '-', CAST(UNIX_MICROS(event_ts) AS STRING))) AS purchase_id,
  ANY_VALUE(user_pseudo_id)   AS user_pseudo_id,
  ANY_VALUE(session_key)      AS session_key,
  MIN(event_ts)               AS purchase_ts,
  IFNULL(MAX(revenue_usd), 0) AS revenue_usd
FROM base_events
WHERE event_name = 'purchase'
GROUP BY purchase_id;


/* ---------------------------------------------------------------------
   0e. USERS
   One row per user with their first-touch (acquisition) channel.
   --------------------------------------------------------------------- */
CREATE TEMP TABLE users AS
SELECT
  user_pseudo_id,
  COALESCE(MIN(first_touch_date), MIN(event_date))                      AS first_touch_date,
  ANY_VALUE(channel_group(first_touch_source, first_touch_medium))      AS first_touch_channel
FROM base_events
GROUP BY user_pseudo_id;


/* =====================================================================
   Q1. BUSINESS OVERVIEW
   Headline numbers for the period.
   ===================================================================== */
SELECT
  (SELECT COUNT(*) FROM base_events)                       AS total_events,
  (SELECT COUNT(*) FROM users)                             AS users,
  (SELECT COUNT(*) FROM sessions)                          AS sessions,
  (SELECT COUNT(*) FROM purchases)                         AS orders,
  (SELECT COUNT(DISTINCT user_pseudo_id) FROM purchases)   AS customers,
  (SELECT ROUND(SUM(revenue_usd), 2) FROM purchases)       AS revenue_usd,
  (SELECT ROUND(AVG(revenue_usd), 2) FROM purchases)       AS avg_order_value_usd,
  ROUND(SAFE_DIVIDE(
    (SELECT COUNT(DISTINCT user_pseudo_id) FROM purchases),
    (SELECT COUNT(*) FROM users)) * 100, 2)                AS user_to_customer_pct;


/* =====================================================================
   Q2. PURCHASE FUNNEL BY DEVICE
   Session-based open funnel: a session counts at a step if it fired
   that event at all. A step rate above 100% means users skipped the
   previous step (e.g. bought without a tracked add_payment_info),
   which is itself a tracking finding worth reporting.
   ===================================================================== */
SELECT
  COALESCE(device, 'All devices')                                              AS device,
  COUNT(*)                                                                     AS sessions,
  COUNTIF(reached_view_item)                                                   AS viewed_item,
  COUNTIF(reached_add_to_cart)                                                 AS added_to_cart,
  COUNTIF(reached_checkout)                                                    AS began_checkout,
  COUNTIF(reached_payment)                                                     AS added_payment,
  COUNTIF(reached_purchase)                                                    AS purchased,
  ROUND(SAFE_DIVIDE(COUNTIF(reached_view_item),   COUNT(*)) * 100, 2)          AS session_to_view_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(reached_add_to_cart), COUNTIF(reached_view_item)) * 100, 2)   AS view_to_cart_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(reached_checkout),    COUNTIF(reached_add_to_cart)) * 100, 2) AS cart_to_checkout_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(reached_payment),     COUNTIF(reached_checkout)) * 100, 2)    AS checkout_to_payment_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(reached_purchase),    COUNTIF(reached_payment)) * 100, 2)     AS payment_to_purchase_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(reached_purchase),    COUNT(*)) * 100, 2)          AS overall_conversion_pct
FROM sessions
GROUP BY ROLLUP (device)
ORDER BY sessions DESC;


/* =====================================================================
   Q3. CHANNEL PERFORMANCE
   Volume (sessions, users), quality (engagement, conversion) and value
   (revenue, revenue per session, AOV) for each session channel.
   ===================================================================== */
WITH session_sales AS (
  SELECT
    session_key,
    COUNT(*)         AS orders,
    SUM(revenue_usd) AS revenue_usd
  FROM purchases
  GROUP BY session_key
)
SELECT
  s.channel,
  COUNT(*)                                                               AS sessions,
  COUNT(DISTINCT s.user_pseudo_id)                                       AS users,
  ROUND(SAFE_DIVIDE(COUNTIF(s.is_engaged), COUNT(*)) * 100, 2)           AS engagement_rate_pct,
  IFNULL(SUM(ss.orders), 0)                                              AS orders,
  ROUND(IFNULL(SUM(ss.revenue_usd), 0), 2)                               AS total_revenue_usd,
  ROUND(SAFE_DIVIDE(SUM(ss.revenue_usd),
                    SUM(SUM(ss.revenue_usd)) OVER ()) * 100, 2)          AS revenue_share_pct,
  ROUND(SAFE_DIVIDE(SUM(ss.orders), COUNT(*)) * 100, 2)                  AS session_conversion_pct,
  ROUND(SAFE_DIVIDE(SUM(ss.revenue_usd), COUNT(*)), 2)                   AS revenue_per_session_usd,
  ROUND(SAFE_DIVIDE(SUM(ss.revenue_usd), SUM(ss.orders)), 2)             AS avg_order_value_usd
FROM sessions AS s
LEFT JOIN session_sales AS ss
  ON ss.session_key = s.session_key
GROUP BY s.channel
ORDER BY total_revenue_usd DESC;


/* =====================================================================
   Q4. ATTRIBUTION MODEL COMPARISON
   - First touch : all credit to the channel that acquired the user
   - Last touch  : all credit to the channel of the purchase session
   - Linear      : credit split equally across every session the user
                   had up to and including the purchase
   Channels whose revenue rises under first touch are "openers" that
   introduce customers; channels that rise under last touch are
   "closers". Budget decisions based on last touch alone undervalue
   the openers.
   ===================================================================== */
WITH first_touch AS (
  SELECT u.first_touch_channel AS channel, p.revenue_usd
  FROM purchases AS p
  JOIN users AS u
    ON u.user_pseudo_id = p.user_pseudo_id
),
last_touch AS (
  SELECT IFNULL(s.channel, 'Unassigned') AS channel, p.revenue_usd
  FROM purchases AS p
  LEFT JOIN sessions AS s
    ON s.session_key = p.session_key
),
linear AS (
  SELECT
    s.channel,
    p.revenue_usd / COUNT(*) OVER (PARTITION BY p.purchase_id) AS revenue_usd
  FROM purchases AS p
  JOIN sessions AS s
    ON  s.user_pseudo_id   = p.user_pseudo_id
    AND s.session_start_ts <= p.purchase_ts
),
combined AS (
  SELECT 'first_touch' AS model, channel, revenue_usd FROM first_touch
  UNION ALL
  SELECT 'last_touch',           channel, revenue_usd FROM last_touch
  UNION ALL
  SELECT 'linear',               channel, revenue_usd FROM linear
)
SELECT
  channel,
  ROUND(SUM(IF(model = 'first_touch', revenue_usd, 0)), 2)  AS first_touch_revenue_usd,
  ROUND(SUM(IF(model = 'last_touch',  revenue_usd, 0)), 2)  AS last_touch_revenue_usd,
  ROUND(SUM(IF(model = 'linear',      revenue_usd, 0)), 2)  AS linear_revenue_usd,
  ROUND(SUM(IF(model = 'last_touch',  revenue_usd, 0))
      - SUM(IF(model = 'first_touch', revenue_usd, 0)), 2)  AS last_minus_first_usd,
  CASE
    WHEN SUM(IF(model = 'first_touch', revenue_usd, 0))
       > SUM(IF(model = 'last_touch',  revenue_usd, 0)) THEN 'Opener (acquires customers)'
    WHEN SUM(IF(model = 'first_touch', revenue_usd, 0))
       < SUM(IF(model = 'last_touch',  revenue_usd, 0)) THEN 'Closer (converts customers)'
    ELSE 'Neutral'
  END                                                       AS channel_role
FROM combined
GROUP BY channel
ORDER BY last_touch_revenue_usd DESC;


/* =====================================================================
   Q5. MONTHLY COHORT RETENTION
   Users grouped by the month of their first visit; shows what share
   came back in later months. The dataset covers 3 months, so the
   November cohort can be followed for months 0-2.
   ===================================================================== */
WITH cohorts AS (
  SELECT
    user_pseudo_id,
    DATE_TRUNC(first_touch_date, MONTH) AS cohort_month
  FROM users
  WHERE first_touch_date BETWEEN DATE '2020-11-01' AND DATE '2021-01-31'
),
activity AS (
  SELECT DISTINCT
    user_pseudo_id,
    DATE_TRUNC(event_date, MONTH) AS activity_month
  FROM base_events
),
cohort_activity AS (
  SELECT
    c.cohort_month,
    DATE_DIFF(a.activity_month, c.cohort_month, MONTH) AS months_since_first_visit,
    COUNT(DISTINCT c.user_pseudo_id)                   AS active_users
  FROM cohorts AS c
  JOIN activity AS a
    ON a.user_pseudo_id = c.user_pseudo_id
  WHERE a.activity_month >= c.cohort_month
  GROUP BY 1, 2
)
SELECT
  cohort_month,
  months_since_first_visit,
  active_users,
  FIRST_VALUE(active_users) OVER w                                AS cohort_size,
  ROUND(SAFE_DIVIDE(active_users, FIRST_VALUE(active_users) OVER w) * 100, 2) AS retention_pct
FROM cohort_activity
WINDOW w AS (PARTITION BY cohort_month ORDER BY months_since_first_visit)
ORDER BY cohort_month, months_since_first_visit;


/* =====================================================================
   Q6. RFM CUSTOMER SEGMENTATION
   Recency  : days since last order (as of 31 Jan 2021)
   Frequency: number of orders
   Monetary : total spend
   Most customers order once in a 3-month window, so frequency uses
   business rules rather than quintiles, and spend uses quartiles.
   ===================================================================== */
CREATE TEMP TABLE customer_segments AS
WITH customers AS (
  SELECT
    user_pseudo_id,
    DATE_DIFF(DATE '2021-01-31', DATE(MAX(purchase_ts)), DAY) AS recency_days,
    COUNT(*)                                                  AS frequency,
    SUM(revenue_usd)                                          AS monetary
  FROM purchases
  GROUP BY user_pseudo_id
),
scored AS (
  SELECT
    *,
    NTILE(4) OVER (ORDER BY monetary DESC) AS spend_quartile   -- 1 = top 25% of spenders
  FROM customers
)
SELECT
  s.*,
  u.first_touch_channel,
  CASE
    WHEN s.frequency >= 2 AND s.recency_days <= 30      THEN '1. Champions'
    WHEN s.frequency >= 2                               THEN '2. Loyal, needs re-engagement'
    WHEN s.recency_days <= 30 AND s.spend_quartile = 1  THEN '3. New high-value'
    WHEN s.recency_days <= 30                           THEN '4. New customers'
    WHEN s.spend_quartile = 1                           THEN '5. At risk, high value'
    ELSE                                                     '6. Hibernating'
  END AS segment
FROM scored AS s
JOIN users AS u
  ON u.user_pseudo_id = s.user_pseudo_id;

SELECT
  segment,
  COUNT(*)                                                         AS customers,
  ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2)                 AS pct_of_customers,
  ROUND(SUM(monetary), 2)                                          AS revenue_usd,
  ROUND(SAFE_DIVIDE(SUM(monetary), SUM(SUM(monetary)) OVER ()) * 100, 2) AS pct_of_revenue,
  ROUND(AVG(monetary), 2)                                          AS avg_spend_usd,
  ROUND(AVG(frequency), 2)                                         AS avg_orders,
  ROUND(AVG(recency_days), 1)                                      AS avg_recency_days
FROM customer_segments
GROUP BY segment
ORDER BY segment;


/* =====================================================================
   Q7. CUSTOMER QUALITY BY ACQUISITION CHANNEL
   Which channels bring customers who spend more and come back?
   This is the question last-click channel reports usually miss.
   ===================================================================== */
SELECT
  first_touch_channel,
  COUNT(*)                                                     AS customers,
  ROUND(AVG(monetary), 2)                                      AS avg_spend_per_customer_usd,
  ROUND(COUNTIF(frequency >= 2) / COUNT(*) * 100, 2)           AS repeat_purchase_rate_pct,
  ROUND(COUNTIF(spend_quartile = 1) / COUNT(*) * 100, 2)       AS pct_top_quartile_spenders
FROM customer_segments
GROUP BY first_touch_channel
ORDER BY avg_spend_per_customer_usd DESC;
