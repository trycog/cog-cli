import threading
import time
from queue_manager import QueueManager
from stages import Stage1, Stage2, Stage3


class Pipeline:
    """Orchestrates the 3-stage pipeline."""

    def __init__(self, num_items):
        self.queue_mgr = QueueManager(stage_capacity=10, feedback_capacity=2)
        self.stage1 = Stage1(self.queue_mgr, num_items)
        self.stage2 = Stage2(self.queue_mgr)
        self.stage3 = Stage3(self.queue_mgr)

    def run(self, timeout=30):
        start = time.time()

        threads = [
            threading.Thread(target=self.stage1.run, name="Stage1"),
            threading.Thread(target=self.stage2.run, name="Stage2"),
            threading.Thread(target=self.stage3.run, name="Stage3"),
        ]

        for t in threads:
            t.daemon = True
            t.start()

        # Wait for completion with timeout
        for t in threads:
            t.join(timeout=timeout)

        elapsed = time.time() - start

        alive = [t.name for t in threads if t.is_alive()]
        if alive:
            print(
                f"TIMEOUT: Pipeline hung after {elapsed:.1f}s. "
                f"Stuck threads: {', '.join(alive)}"
            )
            return None, elapsed

        return self.stage3.results, elapsed
