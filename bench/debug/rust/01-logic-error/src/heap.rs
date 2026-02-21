/// A binary heap entry storing an item with an associated priority.
#[derive(Debug, Clone)]
pub struct HeapEntry {
    pub priority: u32,
    pub item: usize,
}

impl HeapEntry {
    pub fn new(item: usize, priority: u32) -> Self {
        HeapEntry { priority, item }
    }
}

/// Positional map: tracks where each item lives in the heap so we can
/// do O(1) lookup for decrease-key.
#[derive(Debug)]
pub struct PositionMap {
    positions: Vec<Option<usize>>,
}

impl PositionMap {
    pub fn new(capacity: usize) -> Self {
        PositionMap {
            positions: vec![None; capacity],
        }
    }

    pub fn get(&self, item: usize) -> Option<usize> {
        self.positions.get(item).copied().flatten()
    }

    pub fn set(&mut self, item: usize, pos: usize) {
        if item < self.positions.len() {
            self.positions[item] = Some(pos);
        }
    }

    pub fn remove(&mut self, item: usize) {
        if item < self.positions.len() {
            self.positions[item] = None;
        }
    }

    pub fn contains(&self, item: usize) -> bool {
        self.get(item).is_some()
    }
}
