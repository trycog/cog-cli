import math


def mean(values):
    """Calculate arithmetic mean."""
    return sum(values) / len(values)


def variance(values):
    """Calculate population variance."""
    m = mean(values)
    return sum((x - m) ** 2 for x in values) / len(values)


def std_dev(values):
    """Calculate population standard deviation."""
    return math.sqrt(variance(values))
