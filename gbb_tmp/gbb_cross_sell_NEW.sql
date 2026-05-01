with gbb_subscription_actions as (
    select *
    from dev_data_science.mart_analytics.gbb_subscription_actions
),

gbb_customer_order_flags as (
    select *
    from dev_data_science.mart_analytics.gbb_customer_order_portfolios
),

analytics_order_line as (
    select *
    from prod_edg.mart_analytics.analytics_order_line
),

product_map as (
    select distinct
        product_variant_id,
        iff(is_ag1 = true
            and is_qualified_product = true
            and line_item_purchase_type != 'Free Gift', true, false)
            as is_ag1,
        iff(is_agz = true
            and line_item_purchase_type != 'Free Gift', true, false)
            as is_agz
    from
        analytics_order_line
),

actions_with_products as (
    select
        gbb_subscription_actions.customer_id,
        gbb_subscription_actions.action_created_ts,
        gbb_subscription_actions.order_type,
        gbb_subscription_actions.order_id_adjusted,
        gbb_subscription_actions.is_order_pending,
        case
            when product_map.is_ag1 = true
                then gbb_subscription_actions.action
        end as is_ag1_action,
        case
            when product_map.is_agz = true
                then gbb_subscription_actions.action
        end as is_agz_action

    from
        gbb_subscription_actions
    left join product_map
        on to_varchar(gbb_subscription_actions.product_variant) = to_varchar(product_map.product_variant_id)
),

existing_flags as (
    select 
        distinct gbb_customer_order_flags.order_id,
        gbb_customer_order_flags.customer_id,
        gbb_customer_order_flags.order_created_ts,
        gbb_customer_order_flags.prior_order_id,
        gbb_customer_order_flags.prior_order_created_ts,
        gbb_customer_order_flags.is_ag1_otp_crossell,
        gbb_customer_order_flags.is_ag1_sub_crossell,
        gbb_customer_order_flags.is_agz_otp_crossell,
        gbb_customer_order_flags.is_agz_sub_crossell,
        actions_with_products.*exclude(customer_id)
        
    from 
        gbb_customer_order_flags
        left join actions_with_products
            on gbb_customer_order_flags.customer_id = actions_with_products.customer_id
            and gbb_customer_order_flags.prior_order_created_ts < actions_with_products.action_created_ts
            and actions_with_products.action_created_ts < gbb_customer_order_flags.order_created_ts
    ---where actions_with_products.action_created_ts is not null
    where actions_with_products.is_order_pending = false
    order by gbb_customer_order_flags.order_created_ts
),


existing_flags_ts as (
    select
        order_id,
        customer_id,
        order_created_ts,
        is_order_pending,
        prior_order_id,
        prior_order_created_ts,
        is_ag1_otp_crossell,
        is_ag1_sub_crossell,
        is_agz_otp_crossell,
        is_agz_sub_crossell,
        max(case
                when
                    is_ag1_otp_crossell = true
                    and is_ag1_action = 'added'
                    and order_type = 'OTP'
                    then action_created_ts
                when
                    is_ag1_otp_crossell = true
                    then order_created_ts
            end) as ag1_crossell_otp_ts,
        max(case
                when
                    is_ag1_sub_crossell = true
                    and is_ag1_action = 'added'
                    and order_type = 'Sub'
                    then action_created_ts
                when
                    is_ag1_sub_crossell = true
                    then order_created_ts
            end) as ag1_crossell_sub_ts,
         max(case
                when
                    is_agz_otp_crossell = true
                    and is_agz_action = 'added'
                    and order_type = 'OTP'
                    then action_created_ts
                when
                    is_agz_otp_crossell = true
                    then order_created_ts
            end) as agz_crossell_otp_ts,
        max(case
                when
                    is_agz_sub_crossell = true
                    and is_agz_action = 'added'
                    and order_type = 'Sub'
                    then action_created_ts
                 when
                    is_agz_sub_crossell = true
                    then order_created_ts
            end) as agz_crossell_sub_ts,
    from existing_flags
    group by all
),


--select *
--from existing_flags_ts
--where customer_id = '8766296752226' 
---- 8/19 action, 8/25 order
--order by order_created_ts, action_created_ts
---where agz_crossell_sub_ts != order_created_ts
--limit 100
---where order_id = '7442850840674'

pending_with_portofolios as (
    select 
        actions_with_products.*,
        gbb_customer_order_flags.order_id as prior_order_id,
        gbb_customer_order_flags.order_created_ts as prior_order_created_ts,
        object_construct(
        'ag1_product', case
            when gbb_customer_order_flags.current_order_product_portfolio['is_ag1_otp'] = true
            or gbb_customer_order_flags.current_order_product_portfolio['is_ag1_sub'] = true
            or gbb_customer_order_flags.prior_product_portfolio['ag1_product'] = true
            then true else false end,
        'agz_product', case
            when gbb_customer_order_flags.current_order_product_portfolio['is_agz_otp'] = true
            or gbb_customer_order_flags.current_order_product_portfolio['is_agz_sub'] = true
            or gbb_customer_order_flags.prior_product_portfolio['agz_product'] = true
            then true else false end
        ) as prior_product_portfolio,
        rank() over (partition by gbb_customer_order_flags.customer_id order by gbb_customer_order_flags.order_created_ts desc) as ranker
    from 
        actions_with_products
        left join gbb_customer_order_flags
        on actions_with_products.customer_id = gbb_customer_order_flags.customer_id
        and actions_with_products.action_created_ts > gbb_customer_order_flags.order_created_ts
    where actions_with_products.is_order_pending = true
    qualify ranker = 1
),

pending_with_flags as (
    select 
     distinct order_id_adjusted as order_id,
        customer_id,
        null as order_created_ts,
        is_order_pending,
        prior_order_id,
        prior_order_created_ts,
        action_created_ts,
        iff(
            is_ag1_action = 'added'
            and order_type = 'OTP'
            and prior_product_portfolio['ag1_product'] = false
            and prior_product_portfolio['agz_product'] = true,
            true, false
        ) as is_ag1_otp_crossell,
        iff(
            is_ag1_action = 'added'
            and order_type = 'Sub'
            and prior_product_portfolio['ag1_product'] = false
            and prior_product_portfolio['agz_product'] = true,
            true, false
        ) as is_ag1_sub_crossell,
        iff(
            is_agz_action = 'added'
            and order_type = 'OTP'
            and prior_product_portfolio['agz_product'] = false
            and prior_product_portfolio['ag1_product'] = true,
            true, false
        ) as is_agz_otp_crossell,
        iff(
            is_agz_action = 'added'
            and order_type = 'Sub'
            and prior_product_portfolio['agz_product'] = false
            and prior_product_portfolio['ag1_product'] = true,
            true, false
        ) as is_agz_sub_crossell
    from pending_with_portofolios
    where is_ag1_action = 'added' or is_agz_action = 'added'
),

pending_flags_ts as (
select
        order_id,
        customer_id,
        order_created_ts,
        is_order_pending,
        prior_order_id,
        prior_order_created_ts,
        is_ag1_otp_crossell,
        is_ag1_sub_crossell,
        is_agz_otp_crossell,
        is_agz_sub_crossell,
        max(case
                when
                    is_ag1_otp_crossell = true
                    then action_created_ts
            end) as ag1_crossell_otp_ts,
        max(case
                when
                    is_ag1_sub_crossell = true
                    then action_created_ts
            end) as ag1_crossell_sub_ts,
         min(case
                when
                    is_agz_otp_crossell = true
                    then action_created_ts
            end) as agz_crossell_otp_ts,
        max(case
                when
                    is_agz_sub_crossell = true
                    then action_created_ts
            end) as agz_crossell_sub_ts,
    from pending_with_flags
    group by all
),

all_flags_by_ts as (
    select *
    from existing_flags_ts
    union all
    select *
    from pending_flags_ts
),

flags_ts_at_order_level as (
    select
        order_id,
        customer_id,
        order_created_ts,
        is_order_pending,
        prior_order_id,
        prior_order_created_ts,
        max(is_ag1_otp_crossell) as is_ag1_crossell_otp,
        max(is_ag1_sub_crossell) as is_ag1_crossell_sub,
        max(is_agz_otp_crossell) as is_agz_crossell_otp,
        max(is_agz_sub_crossell) as is_agz_crossell_sub,
        
        max(ag1_crossell_otp_ts) as ag1_crossell_otp_ts,
        max(ag1_crossell_sub_ts) as ag1_crossell_sub_ts,
        max(agz_crossell_otp_ts) as agz_crossell_otp_ts,
        max(agz_crossell_sub_ts) as agz_crossell_sub_ts,
        array_size(
            array_distinct(
                array_construct_compact(
                    max(ag1_crossell_otp_ts),
                    max(ag1_crossell_sub_ts),
                    max(agz_crossell_otp_ts),
                    max(agz_crossell_sub_ts)
                )
            )
        ) as unique_action_ts_count,
        array_max(
            array_construct_compact(
                max(ag1_crossell_otp_ts),
                max(ag1_crossell_sub_ts),
                max(agz_crossell_otp_ts),
                max(agz_crossell_sub_ts)
            )
        )::timestamp_ntz as max_action_timestamp
    from all_flags_by_ts
    group by 1, 2, 3, 4, 5, 6
)

select *
from flags_ts_at_order_level
limit 100
