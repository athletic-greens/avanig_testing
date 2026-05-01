with analytics_order_line as (
    select *
    from {{ ref("analytics_order_line") }}
),

ranked_customer_orders as (
    select *
    from {{ ref("gbb_int_ranked_customer_orders") }}
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

order_dictionary as (
    select
        analytics_order_line.order_id,
        object_construct(
            'is_full_size_ag1_original_otp',
            max(
                iff(
                    product_map.is_full_size_ag1_original and analytics_order_line.line_item_purchase_type = 'OTP',
                    true,
                    false
                )
            ),
            'is_full_size_ag1_original_sub',
            max(
                iff(
                    product_map.is_full_size_ag1_original
                    and analytics_order_line.line_item_purchase_type = 'Subscription',
                    true,
                    false
                )
            ),
            'is_full_size_ag1_flavor_otp',
            max(
                iff(
                    product_map.is_full_size_ag1_flavor and analytics_order_line.line_item_purchase_type = 'OTP',
                    true,
                    false
                )
            ),
            'is_full_size_ag1_flavor_sub',
            max(
                iff(
                    product_map.is_full_size_ag1_flavor
                    and analytics_order_line.line_item_purchase_type = 'Subscription',
                    true,
                    false
                )
            ),
            'is_full_size_agz_otp',
            max(
                iff(product_map.is_full_size_agz and analytics_order_line.line_item_purchase_type = 'OTP', true, false)
            ),
            'is_full_size_agz_sub',
            max(
                iff(
                    product_map.is_full_size_agz and analytics_order_line.line_item_purchase_type = 'Subscription',
                    true,
                    false
                )
            )
        ) as order_product_dct
    from
        analytics_order_line
    left join product_map
        on analytics_order_line.product_variant_id = product_map.product_variant_id
    where
        analytics_order_line.is_qualified_product = true
    group by 1
),

orders_with_dcts as (
    select distinct
        ranked_customer_orders.*,
        current_order_dictionary.order_product_dct as current_order_product_dct,
        prior_order_dictionary.order_product_dct as prior_order_product_dct
    from
        ranked_customer_orders
    left join order_dictionary as current_order_dictionary
        on ranked_customer_orders.order_id = current_order_dictionary.order_id
    left join order_dictionary as prior_order_dictionary
        on ranked_customer_orders.prior_order_id = prior_order_dictionary.order_id
),

orders_with_flags as (
    select distinct
        customer_id,
        subscription_id,
        order_id,
        order_created_ts,
        prior_order_id,
        prior_order_created_ts,
        prior_order_product_dct,
        current_order_product_dct,
        ------ flags
        --- flavor upsell
        iff(
            current_order_product_dct['is_full_size_ag1_flavor_otp'] = true
            and prior_order_product_dct['is_full_size_ag1_flavor_otp'] = false
            and prior_order_product_dct['is_full_size_ag1_original_otp'] = true,
            true, false
        ) as is_flavor_upsell_otp,
        iff(
            current_order_product_dct['is_full_size_ag1_flavor_sub'] = true
            and prior_order_product_dct['is_full_size_ag1_flavor_sub'] = false
            and prior_order_product_dct['is_full_size_ag1_original_sub'] = true,
            true, false
        ) as is_flavor_upsell_sub,
        --- flavor downgrade
        iff(
            current_order_product_dct['is_full_size_ag1_original_otp'] = true
            and prior_order_product_dct['is_full_size_ag1_original_otp'] = false
            and prior_order_product_dct['is_full_size_ag1_flavor_otp'] = true,
            true, false
        ) as is_flavor_downgrade_otp,
        iff(
            current_order_product_dct['is_full_size_ag1_original_sub'] = true
            and prior_order_product_dct['is_full_size_ag1_original_sub'] = false
            and prior_order_product_dct['is_full_size_ag1_flavor_sub'] = true,
            true, false
        ) as is_flavor_downgrade_sub,
        --- agz += ag1
        iff((
            current_order_product_dct['is_full_size_ag1_original_otp'] = true
            or current_order_product_dct['is_full_size_ag1_flavor_otp'] = true
        )
        and (
            prior_order_product_dct['is_full_size_ag1_original_otp'] = false
            and prior_order_product_dct['is_full_size_ag1_flavor_otp'] = false
        )
        and prior_order_product_dct['is_full_size_agz_otp'] = true,
        true, false) as is_ag1_crossell_otp,
        iff((
            current_order_product_dct['is_full_size_ag1_original_sub'] = true
            or current_order_product_dct['is_full_size_ag1_flavor_sub'] = true
        )
        and (
            prior_order_product_dct['is_full_size_ag1_original_sub'] = false
            and prior_order_product_dct['is_full_size_ag1_flavor_sub'] = false
        )
        and prior_order_product_dct['is_full_size_agz_sub'] = true,
        true, false) as is_ag1_crossell_sub,
        --- ag1 += agz
        iff(
            current_order_product_dct['is_full_size_agz_otp'] = true
            and prior_order_product_dct['is_full_size_agz_otp'] = false
            and (
                prior_order_product_dct['is_full_size_ag1_original_otp'] = true
                or prior_order_product_dct['is_full_size_ag1_flavor_otp'] = true
            ),
            true, false
        ) as is_agz_crossell_otp,
        iff(
            current_order_product_dct['is_full_size_agz_sub'] = true
            and prior_order_product_dct['is_full_size_agz_sub'] = false
            and (
                prior_order_product_dct['is_full_size_ag1_original_sub'] = true
                or prior_order_product_dct['is_full_size_ag1_flavor_sub'] = true
            ),
            true, false
        ) as is_agz_crossell_sub
    from orders_with_dcts
    where order_created_ts >= '2024-08-01'
)

select *
from orders_with_flags
