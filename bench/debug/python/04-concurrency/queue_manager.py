from queue import Queue


class QueueManager:
    """Manages bounded queues for the pipeline."""

    def __init__(self, stage_capacity=10, feedback_capacity=2):
        self.stage1_to_stage2 = Queue(maxsize=stage_capacity)
        self.stage2_to_stage3 = Queue(maxsize=stage_capacity)
        self.feedback = Queue(maxsize=feedback_capacity)  # Stage 2 -> Stage 1
        self.done_producing = False
        self.done_processing = False
