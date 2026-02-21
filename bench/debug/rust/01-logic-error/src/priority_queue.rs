use crate::heap::{HeapEntry, PositionMap};

/// A minimum priority queue backed by a binary heap.
///
/// Supports insert, extract-min, and decrease-key operations needed
/// for Dijkstra's shortest-path algorithm.
pub struct MinPriorityQueue {
    data: Vec<HeapEntry>,
    pos: PositionMap,
}

impl MinPriorityQueue {
    pub fn new(capacity: usize) -> Self {
        MinPriorityQueue {
            data: Vec::with_capacity(capacity),
            pos: PositionMap::new(capacity),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn contains(&self, item: usize) -> bool {
        self.pos.contains(item)
    }

    /// Insert a new item with the given priority.
    pub fn insert(&mut self, item: usize, priority: u32) {
        let idx = self.data.len();
        self.data.push(HeapEntry::new(item, priority));
        self.pos.set(item, idx);
        self.sift_up(idx);
    }

    /// Remove and return the item with the lowest priority.
    pub fn extract_min(&mut self) -> Option<HeapEntry> {
        if self.data.is_empty() {
            return None;
        }

        let last = self.data.len() - 1;
        self.swap_entries(0, last);

        let entry = self.data.pop().unwrap();
        self.pos.remove(entry.item);

        if !self.data.is_empty() {
            self.sift_down(0);
        }

        Some(entry)
    }

    /// Decrease the priority of an existing item.
    /// Panics if the item is not in the queue or the new priority is higher.
    pub fn decrease_key(&mut self, item: usize, new_priority: u32) {
        if let Some(idx) = self.pos.get(item) {
            debug_assert!(
                new_priority <= self.data[idx].priority,
                "decrease_key called with higher priority"
            );
            self.data[idx].priority = new_priority;
            self.sift_up(idx);
        }
    }

    /// Restore heap property upward from index `idx`.
    ///
    /// For a min-heap, a child should move up when its priority is
    /// LESS THAN its parent's priority.
    fn sift_up(&mut self, mut idx: usize) {
        while idx > 0 {
            let parent = (idx - 1) / 2;
            // BUG: '>' should be '<' for a min-heap.  This comparison
            // moves a child up only when it is GREATER than its parent,
            // which builds a max-heap ordering instead of min-heap.
            if self.data[idx].priority > self.data[parent].priority {
                self.swap_entries(idx, parent);
                idx = parent;
            } else {
                break;
            }
        }
    }

    /// Restore heap property downward from index `idx`.
    fn sift_down(&mut self, mut idx: usize) {
        let len = self.data.len();
        loop {
            let left = 2 * idx + 1;
            let right = 2 * idx + 2;
            let mut smallest = idx;

            // BUG: '>' should be '<' — selects the LARGEST child instead
            // of the smallest, consistent with the broken sift_up above.
            if left < len && self.data[left].priority > self.data[smallest].priority {
                smallest = left;
            }
            if right < len && self.data[right].priority > self.data[smallest].priority {
                smallest = right;
            }

            if smallest != idx {
                self.swap_entries(idx, smallest);
                idx = smallest;
            } else {
                break;
            }
        }
    }

    /// Swap two entries in the heap and update the position map.
    fn swap_entries(&mut self, a: usize, b: usize) {
        self.data.swap(a, b);
        let item_a = self.data[a].item;
        let item_b = self.data[b].item;
        self.pos.set(item_a, a);
        self.pos.set(item_b, b);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_extract() {
        let mut pq = MinPriorityQueue::new(5);
        pq.insert(0, 10);
        pq.insert(1, 3);
        pq.insert(2, 7);

        // With the bug, this extracts the MAX instead of the MIN.
        let first = pq.extract_min().unwrap();
        // Should be item 1 (priority 3) but bug gives item 0 (priority 10).
        println!("Extracted: item={}, priority={}", first.item, first.priority);
    }
}
