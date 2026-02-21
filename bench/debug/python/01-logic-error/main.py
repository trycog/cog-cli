from intervals import Interval
from scheduler import find_max_concurrent


def main():
    """Schedule meetings and report the minimum number of rooms needed.

    The meeting data includes several overlapping sessions spread across
    a wide time range.  The scheduler merges overlapping intervals into
    groups, then computes the peak concurrency within each group.
    """

    meetings = [
        Interval(1.0, 10.0),   # All-hands (long anchor)
        Interval(2.0, 3.0),    # Quick sync
        Interval(5.0, 6.0),    # Design review
        Interval(5.0, 6.0),    # Sprint planning
        Interval(8.0, 9.0),    # Late standup
        Interval(8.0, 9.0),    # Client call
    ]

    rooms = find_max_concurrent(meetings)
    print(f"Rooms needed: {rooms}")


if __name__ == "__main__":
    main()
