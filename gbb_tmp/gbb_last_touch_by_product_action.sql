with gbb_up_down_cross as (
    select *
    from {{ ref("gbb_up_down_cross") }}
),

gbb_int_ranked_sub_orders as (
    select *
    from {{ ref("gbb_int_ranked_customer_orders") }}
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

product_action_line as (
    select
        gbb_up_down_cross.customer_id,
        gbb_up_down_cross.order_id_adjusted,
        gbb_up_down_cross.is_order_pending,
        gbb_up_down_cross.order_created_ts,
        gbb_up_down_cross.prior_order_id,
        gbb_up_down_cross.prior_order_created_ts,
        f.value:product_action::string as product_action,
        coalesce(f.value:action_ts::timestamp, gbb_up_down_cross.order_created_ts) as action_ts
    from gbb_up_down_cross,
        lateral flatten(input => array_construct(
            object_construct(
                'product_action',
                'flavor_upsell_otp',
                'is_active',
                gbb_up_down_cross.is_flavor_upsell_otp,
                'action_ts',
                gbb_up_down_cross.flavor_upsell_otp_ts
            ),
            object_construct(
                'product_action',
                'flavor_upsell_sub',
                'is_active',
                gbb_up_down_cross.is_flavor_upsell_sub,
                'action_ts',
                gbb_up_down_cross.flavor_upsell_sub_ts
            ),
            object_construct(
                'product_action',
                'flavor_downgrade_otp',
                'is_active',
                gbb_up_down_cross.is_flavor_downgrade_otp,
                'action_ts',
                gbb_up_down_cross.flavor_downgrade_otp_ts
            ),
            object_construct(
                'product_action',
                'flavor_downgrade_sub',
                'is_active',
                gbb_up_down_cross.is_flavor_downgrade_sub,
                'action_ts',
                gbb_up_down_cross.flavor_downgrade_sub_ts
            ),
            object_construct(
                'product_action',
                'ag1_crossell_otp',
                'is_active',
                gbb_up_down_cross.is_ag1_crossell_otp,
                'action_ts',
                gbb_up_down_cross.ag1_crossell_otp_ts
            ),
            object_construct(
                'product_action',
                'ag1_crossell_sub',
                'is_active',
                gbb_up_down_cross.is_ag1_crossell_sub,
                'action_ts',
                gbb_up_down_cross.ag1_crossell_sub_ts
            ),
            object_construct(
                'product_action',
                'agz_crossell_otp',
                'is_active',
                gbb_up_down_cross.is_agz_crossell_otp,
                'action_ts',
                gbb_up_down_cross.agz_crossell_otp_ts
            ),
            object_construct(
                'product_action',
                'agz_crossell_sub',
                'is_active',
                gbb_up_down_cross.is_agz_crossell_sub,
                'action_ts',
                gbb_up_down_cross.agz_crossell_sub_ts
            )
        )) as f
    where
        to_boolean(f.value:is_active) = true
),

product_action_line_with_touchpoints as (
    select distinct
        product_action_line.*,
        mta_int_ag_person_customer_id_map.ag_person_id,
        concat_ws('-', product_action_line.customer_id, product_action_line.order_id_adjusted) as cust_order_id,
        mta_int_analytics_web_user_journey.event_occurred_ts,
        mta_int_analytics_web_user_journey.event_occurred_date,
        mta_int_analytics_web_user_journey.attribution_source_sk
    from product_action_line
    left join gbb_int_ranked_sub_orders
        on product_action_line.customer_id = gbb_int_ranked_sub_orders.customer_id
    left join mta_int_ag_person_customer_id_map
        on gbb_int_ranked_sub_orders.customer_id = mta_int_ag_person_customer_id_map.customer_id
    left join mta_int_analytics_web_user_journey
        on mta_int_ag_person_customer_id_map.ag_person_id = mta_int_analytics_web_user_journey.ag_person_id
    where
        mta_int_analytics_web_user_journey.event_occurred_ts > product_action_line.prior_order_created_ts
        and mta_int_analytics_web_user_journey.event_occurred_ts <= product_action_line.action_ts
),

---- issue with LTND being months prior to action ts
all_mta_touchpoints_dedupe as (
    select * exclude (ranked)
    from (
        select
            *,
            row_number() over (
                partition by
                    cust_order_id,
                    product_action,
                    attribution_source_sk,
                    event_occurred_date
                order by event_occurred_ts desc
            ) as ranked

        from product_action_line_with_touchpoints
    )
    where ranked = 1
),

ranked_touch_at_product_action_level as (
    select
        all_mta_touchpoints_dedupe.*,
        row_number() over (
            partition by all_mta_touchpoints_dedupe.cust_order_id, all_mta_touchpoints_dedupe.product_action
            order by all_mta_touchpoints_dedupe.event_occurred_ts desc
        ) as last_touch_rank_raw,
        row_number() over (
            partition by all_mta_touchpoints_dedupe.cust_order_id, all_mta_touchpoints_dedupe.product_action
            order by
                case
                    when attr_src.attribution_source_sk is null then 0
                    when attr_src.attribution_source_sk = 'Direct' then 0
                    else 1
                end desc,
                all_mta_touchpoints_dedupe.event_occurred_ts desc
        ) as last_touch_non_direct_rank
    from all_mta_touchpoints_dedupe
    left join attr_src
        on all_mta_touchpoints_dedupe.attribution_source_sk = attr_src.attribution_source_sk
),

last_touch_non_direct_at_product_action_level as (
    select * exclude (last_touch_rank_raw)
    from ranked_touch_at_product_action_level
    where last_touch_non_direct_rank = 1
)

select *
from last_touch_non_direct_at_product_action_level
