"""Order pricing: combines discount calculation with shipping."""

# Shipping methods assigned to cart positions.  The method for item at
# position i is  SHIPPING_METHODS[i % len(SHIPPING_METHODS)].
SHIPPING_METHODS = ["priority", "free", "economy", "economy"]

SHIPPING_RATES = {
    "priority": 8.00,
    "free": 0.00,
    "economy": 3.00,
}


def calculate_shipping(items):
    """Calculate total shipping cost.

    Each item is matched to a shipping method by its *position* in the
    list.  The rate is multiplied by the item's quantity.
    """
    total_shipping = 0.0
    for i, item in enumerate(items):
        method = SHIPPING_METHODS[i % len(SHIPPING_METHODS)]
        rate = SHIPPING_RATES[method]
        total_shipping += rate * item.quantity
    return total_shipping


def calculate_order_total(items):
    """Calculate the full order total (discounted items + shipping).

    IMPORTANT: ``apply_tiered_discounts`` contains a bug that sorts
    ``items`` in-place.  After it returns, the list is reordered by
    subtotal descending, so ``calculate_shipping`` -- which relies on
    insertion order -- pairs items with the wrong shipping methods.
    """
    from discounts import apply_tiered_discounts

    # This call mutates items (BUG -- sorts in-place)
    discounted = apply_tiered_discounts(items)

    item_total = sum(discounted.values())
    shipping_total = calculate_shipping(items)

    return round(item_total + shipping_total, 2)
