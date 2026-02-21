class CartItem:
    """A single line item in the shopping cart."""

    def __init__(self, product, quantity):
        self.product = product
        self.quantity = quantity

    @property
    def subtotal(self):
        return self.product.price * self.quantity

    def __repr__(self):
        return f"CartItem({self.product.name} x{self.quantity})"

    def __lt__(self, other):
        """Sort by subtotal descending (highest-value items first)."""
        return self.subtotal > other.subtotal


class Cart:
    """Shopping cart that maintains items in insertion order."""

    def __init__(self):
        self.items = []

    def add(self, product, quantity=1):
        """Add a product to the cart.  Items are stored in the order
        they are added -- shipping method assignment depends on this
        order.
        """
        self.items.append(CartItem(product, quantity))

    def get_items(self):
        """Return the internal item list (not a copy)."""
        return self.items
