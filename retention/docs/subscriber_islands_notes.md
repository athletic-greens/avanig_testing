# Customer-level subscriber stock and flows (islands)

Notes on `retention_customer_active_island` and `retention_customer_island_month`, the semantic model
`customer_island_month` and the `subscriber_*` metrics (PR #752). Source of the numbers: the NA MBR slide
"NA active subscribers | net growth & churn" and its tenure-band cut.

## What it does
- **Island**: one unbroken stretch of days on which a customer has at least one ACTIVE subscription. A
  customer's ACTIVE windows from `analytics_subscription_status_history` are merged: a window that starts
  after the running max end of earlier windows opens a new island. `end_date` is exclusive, so a window that
  starts on the previous end date joins the island (a plan swap with no gap is neither churn nor return).
- **Definitions** (per month, customer grain):
  - new = island 1 starts in the month; returning = island 2+ starts in the month
  - churned = an island ends in the month (includes islands that start and end in the same month)
  - opening = island open on the first day of the month (equals the prior month's active at month end)
  - active = island open across month end
  - churn rate = churned / opening
  - tenure = days from island start to month start, for opening islands. Bands: 1-60, 61-121, 122-212,
    213-364, 365-729, 730+ days. Band 0 = started this month.
- **Architecture**: two customer-level dbt tables; MetricFlow aggregates at query time, so region and tenure
  band are sliceable. Slice `region = 'NA'` for the slide. Both tables are full rebuilds.

## Validation (read-only Snowflake, 2026-10-20)
- New logic matches the original slide query exactly for Jul-Sep 2026 (Sep: 12,072 new / 8,339 returning /
  23,034 churned / 282,521 active).
- Sep 2026 tenure-band opening and churned counts match the original band query in all six bands.
- Sum of opening in month m equals sum of active in month m-1 (Mar-Oct 2026).
- The 2026-10-05 pull behind the printed slide had Sep at 12,605 / 8,532 / 23,033 / 283,626. The source SCD2
  has been restated since, so expect small differences against the slide. This is data drift, not logic.

## Known issues and caveats
1. **Tie bug (also in the original slide SQL).** Identical (customer, start, end) windows tie in the window
   ordering, and Snowflake can order ties differently between the two windows, splitting off a spurious island
   (17 of ~4.0M). Fixed with `select distinct`; counts unchanged.
2. **Same-day flickers.** About 117K islands (2.9%) have `end_date <= start_date` (a window that opens and
   closes on one date). Kept for parity with the slide. Each counts as a start and a churn in the same month,
   so net change is unaffected but both flows and churn rate are slightly inflated. Dropping them needs
   slide sign-off.
3. **"Returning" is not "winback".** Returning is subscription-status based (a day with zero active
   subscriptions). `int_customer_engagement_periods` / `int_winback_order` define winback by orders, 180+ days
   since the previous qualified order. The two will not agree.
4. **Customer vs subscription grain.** Counts will not equal `retention_subscription_active_week` or the
   `subscription_*` metrics (a customer with two active subscriptions counts once here).
5. **SCD2 reliability.** `analytics_subscription_status_history` is reliable from 2024-07-11 and validated
   from 2024-11-01. `is_validated_month` flags earlier months; tenure for long-tenured customers is directional.
6. **Band edges** are plain day counts, not the snap-30 `rebill_cohort_month` macro.
7. **Non-additive metrics.** `subscriber_opening` takes the first month and `subscriber_active` the last month
   of a period. Group by `metric_time__month` or filter to one month; with no time grouping the value is the
   earliest / latest month in the model. At quarter or year grain `subscriber_churn_rate` is the period's
   summed churn over the first month's opening.

## Overlap with an existing report
`rpt_daily_subscription_influx_outflux` (and `_mom`, `_wow`) in `mart_analytics` also reports acquired,
churned, net and end-of-month active counts by region. It differs: subscription grain, reads
`uat_subscription_type2`, compares each day with the day before, no new/returning split, no tenure, drops
customers with no region. Nothing in `models/` references it. NA comparison (existing report vs islands):

| Month | Acquired / new+returning | Churned | Active at month end |
|---|---|---|---|
| 2026-07 | 20,622 / 18,684 | 33,389 / 30,657 | 297,747 / 294,029 |
| 2026-08 | 22,574 / 20,241 | 31,731 / 29,126 | 288,590 / 285,144 |
| 2026-09 | 22,165 / 20,411 | 25,192 / 23,034 | 285,563 / 282,521 |

Flows differ by about 8-10% and active by about 1%. The cause was not isolated; likely subscription vs
customer grain, the different source table, and day-over-day comparison counting a swap as churn plus
acquisition. Open decision: keep the old report, replace it, or document it as the subscription-grain view.

## Open items
- `dbt build` on both models and `dbt sl validate` (not run when the PR was written).
- Query `subscriber_churn_rate` by `tenure_band_code` through MetricFlow and compare with the tenure slide.
- Left out for now: prior-year (`offset_window`) metrics and a band-0 starter churn rate.
- Possible cleanup: `retention_customer_engagement_periods` looks like a stale orphan table; check lineage
  before dropping.
