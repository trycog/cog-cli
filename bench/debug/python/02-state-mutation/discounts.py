def apply_tiered_discounts(items):
    """Apply tiered discounts based on item value.

    The highest-value line items receive the largest discounts:

        Tier 1 (most expensive) : 15% off
        Tier 2                  : 10% off
        Tier 3+                 :  5% off

    Returns a dict mapping product name -> discounted line-item total.

    BUG: sorts the *original* list in-place with ``items.sort()``
    instead of working on a copy with ``sorted(items)``.  This silently
    reorders the caller's list, breaking any logic that relies on
    insertion order (e.g. the shipping calculator).
    """
    # BUG: mutates the caller's list -- should be:
    #     sorted_items = sorted(items)
    items.sort()

    discounted_prices = {}
    for i, item in enumerate(items):
        if i == 0:
            discount = 0.15     # tier 1
        elif i == 1:
            discount = 0.10     # tier 2
        else:
            discount = 0.05     # tier 3+

        discounted_prices[item.product.name] = round(
            item.subtotal * (1 - discount), 2
        )

    return discounted_prices
