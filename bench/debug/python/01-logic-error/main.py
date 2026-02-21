from intervals import Interval
from scheduler import find_max_concurrent


def main():
    """Schedule meetings and report the minimum number of rooms needed.

    The meeting data is arranged in two back-to-back blocks that share
    an exact boundary point (10:00).  Meetings within each block run
    concurrently, but the two blocks are merely *adjacent* -- they do
    NOT overlap.

    Correct answer  : 4 rooms  (2 per block, blocks are independent)
    Answer with bug : 2 rooms  (blocks merge into one, peak is still 2)
    """

    meetings = [
        # --- Morning block: two parallel meetings, 9:00 - 10:00 ---
        Interval(9.0, 10.0),    # Engineering standup
        Interval(9.0, 10.0),    # Client sync

        # --- Mid-morning block: two parallel meetings, 10:00 - 11:00 ---
        # Adjacent to the morning block (touch at 10:00) but do NOT
        # overlap: the morning meetings end at 10:00, these start at
        # 10:00.  With the merger bug (<= instead of <), the boundary
        # comparison 10.0 <= 10.0 evaluates to True, so the blocks are
        # incorrectly merged into a single group.
        Interval(10.0, 11.0),   # Design review
        Interval(10.0, 11.0),   # Sprint planning
    ]

    rooms = find_max_concurrent(meetings)
    print(f"Rooms needed: {rooms}")


if __name__ == "__main__":
    main()
