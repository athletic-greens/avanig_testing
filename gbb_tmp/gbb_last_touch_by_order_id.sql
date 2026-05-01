with gbb_up_down_cross as (
    select *
    from {{ ref("gbb_up_down_cross") }}
),

mta_int_ag_person_customer_id_map as (
    select *
    from {{ ref("mta_int_ag_person_customer_id_map") }}
),

mta_int_analytics_web_user_journey as (
    select *
    from {{ ref("mta_int_analytics_web_user_journey") }}
),

attr_src as (
    select *
    from {{ ref("analytics_attribution_source") }}
),

actions_with_ag_person_id as (
    select distinct
        gbb_up_down_cross.*,
        mta_int_ag_person_customer_id_map.ag_person_id
    from
        gbb_up_down_cross
    left join mta_int_ag_person_customer_id_map
        on gbb_up_down_cross.customer_id = mta_int_ag_person_customer_id_map.customer_id
    where
        gbb_up_down_cross.prior_order_created_ts is not null
        and gbb_up_down_cross.unique_action_ts_count > 0
),

actions_with_touchpoints as (
    select distinct
        actions_with_ag_person_id.*,
        concat_ws('-', actions_with_ag_person_id.customer_id, actions_with_ag_person_id.order_id_adjusted)
            as cust_order_id,
        mta_int_analytics_web_user_journey.event_occurred_ts,
        mta_int_analytics_web_user_journey.event_occurred_date,
        mta_int_analytics_web_user_journey.attribution_source_sk
    from actions_with_ag_person_id
    left join mta_int_analytics_web_user_journey
        on actions_with_ag_person_id.ag_person_id = mta_int_analytics_web_user_journey.ag_person_id
    where
        mta_int_analytics_web_user_journey.event_occurred_ts > actions_with_ag_person_id.prior_order_created_ts
        and mta_int_analytics_web_user_journey.event_occurred_ts <= actions_with_ag_person_id.max_action_timestamp
),

all_mta_touchpoints_dedupe as (
    select * exclude (ranked)
    from (
        select
            *,
            row_number() over (
                partition by
                    cust_order_id,
                    attribution_source_sk,
                    event_occurred_date
                order by event_occurred_ts desc
            ) as ranked

        from actions_with_touchpoints
    )
    where ranked = 1
),

last_touch_at_order_level as (
    select
        all_mta_touchpoints_dedupe.*,
        row_number() over (
            partition by all_mta_touchpoints_dedupe.cust_order_id
            order by all_mta_touchpoints_dedupe.event_occurred_ts desc
        ) as last_touch_rank_raw,
        row_number() over (
            partition by all_mta_touchpoints_dedupe.cust_order_id
            order by
                case
                    when attr_src.attribution_source_sk is null then 0
                    when attr_src.attribution_source_sk = 'Direct' then 0
                    else 1
                end desc,
                all_mta_touchpoints_dedupe.event_occurred_ts desc
        ) as last_touch_non_direct
    --- LTND issue: touchpoints between 9/15 and 11/22; both touchpoints in nov are MFR, therefore lt from september but order placed in november
    --- work on attributing at product level
    from all_mta_touchpoints_dedupe
    left join attr_src
        on all_mta_touchpoints_dedupe.attribution_source_sk = attr_src.attribution_source_sk
)

select * exclude (last_touch_rank_raw, last_touch_non_direct)
from last_touch_at_order_level
where last_touch_non_direct = 1
