import sys


def add(a, b):
    result = a + b        # line 5
    return result          # line 6


def multiply(a, b):
    result = a * b        # line 10
    return result          # line 11


def compute(x, y):
    sum_ = add(x, y)              # line 15
    product = multiply(x, y)      # line 16
    final = sum_ + product        # line 17
    return final                   # line 18


def loop_sum(n):
    total = 0                      # line 22
    for i in range(1, n + 1):
        total = add(total, i)     # line 24
    return total                   # line 25


def factorial(n):
    if n <= 1:                     # line 29
        return 1                   # line 30
    return n * factorial(n - 1)   # line 31


def main():
    x = 10                                 # line 35
    y = 20                                 # line 36
    result1 = compute(x, y)               # line 37
    print(f"compute = {result1}")          # line 38
    result2 = loop_sum(5)                  # line 39
    print(f"loop_sum = {result2}")         # line 40
    result3 = factorial(5)                 # line 41
    print(f"fact = {result3}")             # line 42
    return 0                               # line 43


if __name__ == "__main__":
    sys.exit(main())
