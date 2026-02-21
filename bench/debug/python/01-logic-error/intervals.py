class Interval:
    """Represents a time interval [start, end)."""

    def __init__(self, start, end):
        if start >= end:
            raise ValueError(
                f"Invalid interval: start ({start}) must be < end ({end})"
            )
        self.start = start
        self.end = end

    def __repr__(self):
        return f"[{self.start}, {self.end}]"

    def __eq__(self, other):
        return self.start == other.start and self.end == other.end

    def __hash__(self):
        return hash((self.start, self.end))

    def __lt__(self, other):
        if self.start == other.start:
            return self.end < other.end
        return self.start < other.start
