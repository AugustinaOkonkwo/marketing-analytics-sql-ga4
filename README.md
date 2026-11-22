# Marketing Funnel & Channel Attribution Analysis (SQL / BigQuery)

Which marketing channels actually drive revenue, where customers drop off, and which channels bring the customers worth keeping. Analysed with SQL on Google's public GA4 e-commerce dataset.

## The data
- **Source:** `bigquery-public-data.ga4_obfuscated_sample_ecommerce` (Google Merchandise Store)
- **Period:** 1 Nov 2020 – 31 Jan 2021
- **Grain:** raw GA4 event export (nested `event_params`, `items` and `ecommerce` fields)

## Business questions
1. What do traffic, customers and revenue look like for the period?
2. Where do users drop off in the purchase funnel, by device?
3. Which channels drive revenue, and which drive quality traffic?
4. How does channel credit change under first-touch, last-touch and linear attribution?
5. Do users come back after their first visit?
6. Who are the most valuable customers (RFM)?
7. Which acquisition channels bring the most valuable customers?

## Approach
The script builds five reusable temp tables (`base_events`, `sessions`, `purchases`, `users`, `customer_segments`) so the public dataset is scanned once, then answers each question with its own query.

**SQL techniques used:** `UNNEST` on nested GA4 parameters, CTEs, temp tables and a temp UDF for channel grouping, window functions (`NTILE`, `FIRST_VALUE`, `COUNT() OVER`, `SUM() OVER`), `ROLLUP`, `ARRAY_AGG ... ORDER BY ... LIMIT`, and time-bounded joins for linear attribution.

## Key findings
*(Fill these in from your query results. Use numbers, not adjectives.)*
1. **Funnel:** the biggest drop is between ___ and ___ (___%), and it's worse on ___.
2. **Channels:** ___ brings the most sessions, but ___ has the highest revenue per session.
3. **Attribution:** ___ gains ___% more credit under first touch, so it opens customer journeys that last-click reporting undervalues.
4. **Retention:** ___% of the November cohort came back in December.
5. **Customers:** ___% of customers generate ___% of revenue.

## Recommendations
1. ___
2. ___
3. ___

## How to run
1. Open the [BigQuery console](https://console.cloud.google.com/bigquery). The free sandbox works.
2. Paste `marketing_analytics_ga4.sql` and run the whole script.
3. Each query's result opens in its own tab under the script results.

## Dashboard
*(Link or screenshot of your Power BI dashboard.)*

## Author
**Tina Okonkwo**, Data & Digital Technology Professional · [LinkedIn](#) · [Portfolio](#)
