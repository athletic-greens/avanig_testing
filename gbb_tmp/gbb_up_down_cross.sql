with gbb_subscription_actions as (
    select *
    from {{ ref("gbb_subscription_actions") }}
),

gbb_customer_order_flags as (
    select *
    from {{ ref("gbb_customer_order_flags") }}
),

analytics_order_line as (
    select *
    from {{ ref("analytics_order_line") }}
),

product_map as (
    select distinct
        product_variant_id,
        iff(is_full_size_ag1 = true and coalesce(flavor, 'Original') = 'Original', true, false)
            as is_full_size_ag1_original,
        iff(is_full_size_ag1 = true and flavor in ('Citrus', 'Tropical', 'Berry'), true, false)
            as is_full_size_ag1_flavor,
        is_full_size_agz
    from
        analytics_order_line
    where
        line_item_purchase_type != 'Free Gift'
        and is_qualified_product = true
),

actions_with_products as (
    select
        gbb_subscription_actions.customer_id,
        gbb_subscription_actions.action_created_ts,
        gbb_subscription_actions.order_type,
        case
            when product_map.is_full_size_ag1_original = true
                then gbb_subscription_actions.action
        end as full_size_ag1_original_action,
        case
            when product_map.is_full_size_ag1_flavor = true
                then gbb_subscription_actions.action
        end as full_size_ag1_flavor_action,
        case
            when product_map.is_full_size_agz = true
                then gbb_subscription_actions.action
        end as full_size_agz_action,
        gbb_subscription_actions.order_id_adjusted,
        gbb_subscription_actions.order_created_ts,
        gbb_subscription_actions.is_order_pending,
        gbb_subscription_actions.current_order_rank_by_customer,
        gbb_subscription_actions.prior_order_rank_by_customer,
        gbb_subscription_actions.prior_order_id,
        gbb_subscription_actions.prior_order_created_ts

    from
        gbb_subscription_actions
    left join product_map
        on to_varchar(gbb_subscription_actions.product_variant) = to_varchar(product_map.product_variant_id)
),

existing_orders as (
    select
        actions_with_products.order_id_adjusted,
        gbb_customer_order_flags.* exclude (order_id),
        actions_with_products.* exclude (
            customer_id,
            order_id_adjusted,
            order_created_ts,
            prior_order_id,
            prior_order_created_ts,
            current_order_rank_by_customer,
            prior_order_rank_by_customer
        ),
        coalesce(actions_with_products.action_created_ts, gbb_customer_order_flags.order_created_ts) as reporting_ts
    from
        gbb_customer_order_flags
    left join actions_with_products
        on gbb_customer_order_flags.order_id = actions_with_products.order_id_adjusted
    where
        actions_with_products.is_order_pending = false
),

existing_flags_ts as (
    select
        customer_id,
        order_id_adjusted,
        is_order_pending,
        order_created_ts,
        prior_order_id,
        prior_order_created_ts,
        is_flavor_upsell_otp,
        is_flavor_upsell_sub,
        is_flavor_downgrade_otp,
        is_flavor_downgrade_sub,
        is_ag1_crossell_otp,
        is_ag1_crossell_sub,
        is_agz_crossell_otp,
        is_agz_crossell_sub,
        ----- flavor upsell
        max(case
            when
                is_flavor_upsell_otp = true
                and coalesce(full_size_ag1_flavor_action, 'added') = 'added'
                and coalesce(order_type, 'OTP') = 'OTP'
                then reporting_ts
        end) as flavor_upsell_otp_ts,
        max(case
            when
                is_flavor_upsell_sub = true
                and coalesce(full_size_ag1_flavor_action, 'added') = 'added'
                and coalesce(order_type, 'Sub') = 'Sub'
                then reporting_ts
        end) as flavor_upsell_sub_ts,
        ----- flavor downgrade
        max(case
            when
                is_flavor_downgrade_otp = true
                and coalesce(full_size_ag1_original_action, 'added') = 'added'
                and coalesce(order_type, 'OTP') = 'OTP'
                then reporting_ts
        end) as flavor_downgrade_otp_ts,
        max(case
            when
                is_flavor_downgrade_sub = true
                and coalesce(full_size_ag1_original_action, 'added') = 'added'
                and coalesce(order_type, 'Sub') = 'Sub'
                then reporting_ts
        end) as flavor_downgrade_sub_ts,
        ----- agz += ag1
        max(case
            when
                is_ag1_crossell_otp = true
                and (
                    coalesce(full_size_ag1_original_action, 'added') = 'added'
                    or coalesce(full_size_ag1_flavor_action, 'added') = 'added'
                )
                and coalesce(order_type, 'OTP') = 'OTP'
                then reporting_ts
        end) as ag1_crossell_otp_ts,
        max(case
            when
                is_ag1_crossell_sub = true
                and (
                    coalesce(full_size_ag1_original_action, 'added') = 'added'
                    or coalesce(full_size_ag1_flavor_action, 'added') = 'added'
                )
                and coalesce(order_type, 'Sub') = 'Sub'
                then reporting_ts
        end) as ag1_crossell_sub_ts,
        ----- ag1 += agz
        max(case
            when
                is_agz_crossell_otp = true
                and coalesce(full_size_agz_action, 'added') = 'added'
                and coalesce(order_type, 'OTP') = 'OTP'
                then reporting_ts
        end) as agz_crossell_otp_ts,
        max(case
            when
                is_agz_crossell_sub = true
                and coalesce(full_size_agz_action, 'added') = 'added'
                and coalesce(order_type, 'Sub') = 'Sub'
                then reporting_ts
        end) as agz_crossell_sub_ts
    from existing_orders
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
),

pending_order_flags as (
    select distinct
        actions_with_products.customer_id,
        actions_with_products.action_created_ts,
        actions_with_products.order_id_adjusted,
        actions_with_products.order_type,
        actions_with_products.is_order_pending,
        actions_with_products.full_size_ag1_flavor_action,
        actions_with_products.full_size_ag1_original_action,
        actions_with_products.full_size_agz_action,
        gbb_customer_order_flags.prior_order_product_dct,
        gbb_customer_order_flags.prior_order_id,
        gbb_customer_order_flags.prior_order_created_ts,
        --- flavor upsell
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_otp'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_otp'] = true
            and actions_with_products.full_size_ag1_flavor_action = 'added'
            and actions_with_products.order_type = 'OTP', true, false
        ) as is_flavor_upsell_otp,
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_sub'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_sub'] = true
            and actions_with_products.full_size_ag1_flavor_action = 'added'
            and actions_with_products.order_type = 'Sub', true, false
        ) as is_flavor_upsell_sub,
        --- flavor downgrade
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_otp'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_otp'] = true
            and actions_with_products.full_size_ag1_original_action = 'added'
            and actions_with_products.order_type = 'OTP', true, false
        ) as is_flavor_downgrade_otp,
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_sub'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_sub'] = true
            and actions_with_products.full_size_ag1_original_action = 'added'
            and actions_with_products.order_type = 'Sub', true, false
        ) as is_flavor_downgrade_sub,
        ---- agz += ag1
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_otp'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_otp'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_agz_otp'] = true
            and (
                actions_with_products.full_size_ag1_flavor_action = 'added'
                or actions_with_products.full_size_ag1_original_action = 'added'
            )
            and actions_with_products.order_type = 'OTP', true, false
        ) as is_ag1_crossell_otp,
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_sub'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_sub'] = false
            and gbb_customer_order_flags.prior_order_product_dct['is_full_size_agz_sub'] = true
            and (
                actions_with_products.full_size_ag1_flavor_action = 'added'
                or actions_with_products.full_size_ag1_original_action = 'added'
            )
            and actions_with_products.order_type = 'Sub', true, false
        ) as is_ag1_crossell_sub,
        ---- ag1 += agz
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_agz_otp'] = false
            and (
                gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_otp'] = true
                or gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_otp'] = true
            )
            and actions_with_products.full_size_agz_action = 'added'
            and actions_with_products.order_type = 'OTP', true, false
        ) as is_agz_crossell_otp,
        iff(
            gbb_customer_order_flags.prior_order_product_dct['is_full_size_agz_sub'] = false
            and (
                gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_original_sub'] = true
                or gbb_customer_order_flags.prior_order_product_dct['is_full_size_ag1_flavor_sub'] = true
            )
            and actions_with_products.full_size_agz_action = 'added'
            and actions_with_products.order_type = 'Sub', true, false
        ) as is_agz_crossell_sub

    from
        actions_with_products
    left join gbb_customer_order_flags
        on actions_with_products.prior_order_id = gbb_customer_order_flags.prior_order_id
    where
        actions_with_products.is_order_pending = true
),

pending_flags_ts as (
    select
        customer_id,
        order_id_adjusted,
        is_order_pending,
        null as order_created_ts,
        prior_order_id,
        prior_order_created_ts,
        is_flavor_upsell_otp,
        is_flavor_upsell_sub,
        is_flavor_downgrade_otp,
        is_flavor_downgrade_sub,
        is_ag1_crossell_otp,
        is_ag1_crossell_sub,
        is_agz_crossell_otp,
        is_agz_crossell_sub,
        max(case when is_flavor_upsell_otp = true then action_created_ts end) as flavor_upsell_otp_ts,
        max(case when is_flavor_upsell_sub = true then action_created_ts end) as flavor_upsell_sub_ts,
        max(case when is_flavor_downgrade_otp = true then action_created_ts end) as flavor_downgrade_otp_ts,
        max(case when is_flavor_downgrade_sub = true then action_created_ts end) as flavor_downgrade_sub_ts,
        max(case when is_ag1_crossell_otp = true then action_created_ts end) as ag1_crossell_otp_ts,
        max(case when is_ag1_crossell_sub = true then action_created_ts end) as ag1_crossell_sub_ts,
        max(case when is_agz_crossell_otp = true then action_created_ts end) as agz_crossell_otp_ts,
        max(case when is_agz_crossell_sub = true then action_created_ts end) as agz_crossell_sub_ts
    from pending_order_flags
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
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
        customer_id,
        order_id_adjusted,
        is_order_pending,
        order_created_ts,
        prior_order_id,
        prior_order_created_ts,
        max(is_flavor_upsell_otp) as is_flavor_upsell_otp,
        max(is_flavor_upsell_sub) as is_flavor_upsell_sub,
        max(is_flavor_downgrade_otp) as is_flavor_downgrade_otp,
        max(is_flavor_downgrade_sub) as is_flavor_downgrade_sub,
        max(is_ag1_crossell_otp) as is_ag1_crossell_otp,
        max(is_ag1_crossell_sub) as is_ag1_crossell_sub,
        max(is_agz_crossell_otp) as is_agz_crossell_otp,
        max(is_agz_crossell_sub) as is_agz_crossell_sub,
        max(flavor_upsell_otp_ts) as flavor_upsell_otp_ts,
        max(flavor_upsell_sub_ts) as flavor_upsell_sub_ts,
        max(flavor_downgrade_otp_ts) as flavor_downgrade_otp_ts,
        max(flavor_downgrade_sub_ts) as flavor_downgrade_sub_ts,
        max(ag1_crossell_otp_ts) as ag1_crossell_otp_ts,
        max(ag1_crossell_sub_ts) as ag1_crossell_sub_ts,
        max(agz_crossell_otp_ts) as agz_crossell_otp_ts,
        max(agz_crossell_sub_ts) as agz_crossell_sub_ts,
        array_size(
            array_distinct(
                array_construct_compact(
                    max(flavor_upsell_otp_ts),
                    max(flavor_upsell_sub_ts),
                    max(flavor_downgrade_otp_ts),
                    max(flavor_downgrade_sub_ts),
                    max(ag1_crossell_otp_ts),
                    max(ag1_crossell_sub_ts),
                    max(agz_crossell_otp_ts),
                    max(agz_crossell_sub_ts)
                )
            )
        ) as unique_action_ts_count,
        array_max(
            array_construct_compact(
                max(flavor_upsell_otp_ts),
                max(flavor_upsell_sub_ts),
                max(flavor_downgrade_otp_ts),
                max(flavor_downgrade_sub_ts),
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
