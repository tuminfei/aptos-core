module poto_experimental::order_book_utils {
    friend poto_experimental::bulk_order_book;
    friend poto_experimental::single_order_book;
    friend poto_experimental::price_time_index;
    friend poto_experimental::pending_order_book_index;
    friend poto_experimental::pre_cancellation_tracker;
    friend poto_experimental::dead_mans_switch_tracker;

    use poto_std::big_ordered_map::{Self, BigOrderedMap};

    const BIG_MAP_INNER_DEGREE: u16 = 64;
    const BIG_MAP_LEAF_DEGREE: u16 = 32;

    public(friend) fun new_default_big_ordered_map<K: store, V: store>()
        : BigOrderedMap<K, V> {
        big_ordered_map::new_with_config(
            BIG_MAP_INNER_DEGREE,
            BIG_MAP_LEAF_DEGREE,
            true
        )
    }
}
