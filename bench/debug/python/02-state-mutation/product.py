class Product:
    """A product available in the store."""

    def __init__(self, name, price, weight):
        self.name = name
        self.price = price      # unit price in dollars
        self.weight = weight    # weight in kg (used for shipping)

    def __repr__(self):
        return f"Product({self.name}, ${self.price:.2f})"

    def __lt__(self, other):
        """Sort by price descending for discount tier assignment."""
        return self.price > other.price
