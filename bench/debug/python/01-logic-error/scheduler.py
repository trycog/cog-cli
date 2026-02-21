from merger import merge_intervals


def find_max_concurrent(intervals):
    """Determine the minimum number of rooms needed for all meetings.

    Strategy
    --------
    1. Partition intervals into groups of mutually-overlapping meetings
       using the merger.
    2. Within each group, run a sweep-line algorithm to find the peak
       number of simultaneous meetings.
    3. Sum the peaks across all groups -- meetings in different groups
       never overlap, so their rooms are reusable across groups.
    """
    if not intervals:
        return 0

    groups = merge_intervals(intervals)

    total_rooms = 0
    for group in groups:
        # Build a list of start/end events
        events = []
        for iv in group:
            events.append((iv.start, 1))    # meeting starts
            events.append((iv.end, -1))     # meeting ends

        # Sort by time; at the same time, process ends (-1) before
        # starts (+1) so that a room freed at time T is available for
        # a meeting starting at time T.
        events.sort(key=lambda e: (e[0], e[1]))

        concurrent = 0
        peak = 0
        for _time, delta in events:
            concurrent += delta
            peak = max(peak, concurrent)

        total_rooms += peak

    return total_rooms
