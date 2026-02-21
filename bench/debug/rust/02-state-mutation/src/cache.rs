use std::collections::HashMap;
use std::hash::Hash;

use crate::lru::DoublyLinkedList;

/// A fixed-capacity LRU (Least Recently Used) cache.
///
/// Combines a `HashMap` for O(1) key lookup with an index-based doubly
/// linked list that maintains access order so the least-recently-used
/// entry can be evicted in O(1).
pub struct LRUCache<K: Clone + Eq + Hash + std::fmt::Debug, V: Clone + std::fmt::Debug> {
    capacity: usize,
    map: HashMap<K, usize>, // key -> node index in the list
    list: DoublyLinkedList<K, V>,
}

impl<K: Clone + Eq + Hash + std::fmt::Debug, V: Clone + PartialEq + std::fmt::Debug> LRUCache<K, V> {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "cache capacity must be > 0");
        LRUCache {
            capacity,
            map: HashMap::with_capacity(capacity),
            list: DoublyLinkedList::new(),
        }
    }

    /// Retrieve a value by key, marking it as most-recently-used.
    ///
    /// Returns `None` on a cache miss.
    pub fn get(&mut self, key: &K) -> Option<&V> {
        if let Some(&idx) = self.map.get(key) {
            // Move to front = most recently used.
            self.list.move_to_front(idx);
            self.list.get_value(idx)
        } else {
            None
        }
    }

    /// Insert or update a key-value pair.
    ///
    /// If the cache is full, the least-recently-used entry is evicted.
    pub fn put(&mut self, key: K, value: V) {
        // If the key already exists, update in place.
        if let Some(&idx) = self.map.get(&key) {
            self.list.update_value(idx, value);
            self.list.move_to_front(idx);
            return;
        }

        // Evict LRU if at capacity.
        if self.map.len() >= self.capacity {
            if let Some(evicted_key) = self.list.remove_tail() {
                self.map.remove(&evicted_key);
            }
        }

        // Insert new entry at the front.
        let idx = self.list.push_front(key.clone(), value);
        self.map.insert(key, idx);
    }

    /// Check whether `key` is present without affecting access order.
    #[allow(dead_code)]
    pub fn contains(&self, key: &K) -> bool {
        self.map.contains_key(key)
    }

    /// Current number of entries.
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.map.len()
    }
}
