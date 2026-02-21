from intervals import Interval


def overlaps(a, b):
    """Check if two intervals overlap.

    Two intervals [a.start, a.end) and [b.start, b.end) overlap when
    each one starts before the other ends.  The correct check uses
    strict inequality (<) because the end-point is exclusive: intervals
    that merely touch at a boundary, like [1, 3] and [3, 5], are
    adjacent but NOT overlapping.

    BUG: uses <= instead of <, so adjacent intervals that share an
    endpoint are incorrectly reported as overlapping.
    """
    # BUG: should be  a.start < b.end and b.start < a.end
    return a.start <= b.end and b.start <= a.end


def merge_intervals(intervals):
    """Merge overlapping intervals into groups.

    Returns a list of groups, where each group is a list of intervals
    that mutually overlap (directly or transitively).
    """
    if not intervals:
        return []

    sorted_intervals = sorted(intervals)
    groups = []
    current_group = [sorted_intervals[0]]
    current_end = sorted_intervals[0].end

    for iv in sorted_intervals[1:]:
        # Extend the running envelope and check overlap against it
        if overlaps(Interval(current_group[0].start, current_end), iv):
            current_group.append(iv)
            current_end = max(current_end, iv.end)
        else:
            groups.append(current_group)
            current_group = [iv]
            current_end = iv.end

    groups.append(current_group)
    return groups
