import sys


global_count = 100                     # line 4


class Point:                           # line 7
    def __init__(self, x, y, name):
        self.x = x                     # line 9
        self.y = y                     # line 10
        self.name = name               # line 11


def modify(val, delta):
    return val + delta                 # line 15


def process(a, b, c):
    local1 = a + b                     # line 19
    local2 = b + c                     # line 20
    local3 = local1 * local2           # line 21
    return local3                      # line 22


def main():
    x = 5                              # line 26
    y = 10                             # line 27
    z = 15                             # line 28
    pt = Point(100, 200, "origin")     # line 29
    x = modify(x, 3)                   # line 30
    result = process(x, y, z)          # line 31
    print(f"x={x} result={result} global={global_count}")  # line 32
    print(f"pt=({pt.x},{pt.y},{pt.name})")                 # line 33
    return 0                           # line 34


if __name__ == "__main__":
    sys.exit(main())
