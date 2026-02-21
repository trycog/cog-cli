from product import Product
from cart import Cart
from pricing import calculate_order_total


def main():
    """Build a shopping cart and print the order total.

    Items are added in a specific order because the shipping calculator
    assigns shipping methods by position:

        Position 0 : priority  ($8.00/ea)
        Position 1 : free      ($0.00/ea)
        Position 2 : economy   ($3.00/ea)
        Position 3 : economy   ($3.00/ea)
    """
    cart = Cart()

    # Insertion order matters for shipping assignment
    cart.add(Product("Notebook",   12.00, 0.4), quantity=2)   # $24 subtotal
    cart.add(Product("Headphones", 35.00, 0.3), quantity=1)   # $35 subtotal
    cart.add(Product("USB Cable",   6.00, 0.1), quantity=3)   # $18 subtotal
    cart.add(Product("Mouse Pad",  20.00, 0.5), quantity=1)   # $20 subtotal

    total = calculate_order_total(cart.get_items())
    print(f"Order total: ${total:.2f}")


if __name__ == "__main__":
    main()
