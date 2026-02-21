from intervals import Interval


def overlaps(a, b):
    """Check if two intervals overlap.

    Two intervals [a.start, a.end) and [b.start, b.end) overlap when
    each one starts before the other ends.
    """
    return a.start < b.end and b.start < a.end


class GroupTracker:
    """Track a group of overlapping intervals.

    Intervals are added in sorted order (by start time).  The tracker
    exposes a ``span`` property that returns the bounding envelope of
    the entire group, used to test whether the next interval overlaps.
    """

    def __init__(self, first_interval):
        self.intervals = [first_interval]

    @property
    def span(self):
        """Return an interval covering the full extent of this group.

        Because intervals are added in sorted order, the first interval
        has the earliest start and the last interval has the latest end.
        """
        return Interval(self.intervals[0].start, self.intervals[-1].end)

    def add(self, interval):
        self.intervals.append(interval)

    def reset(self, interval):
        finished = list(self.intervals)
        self.intervals = [interval]
        return finished


def merge_intervals(intervals):
    """Merge overlapping intervals into groups."""
    if not intervals:
        return []

    sorted_intervals = sorted(intervals)
    tracker = GroupTracker(sorted_intervals[0])
    groups = []

    for iv in sorted_intervals[1:]:
        if overlaps(tracker.span, iv):
            tracker.add(iv)
        else:
            groups.append(tracker.reset(iv))

    groups.append(tracker.intervals)
    return groups
