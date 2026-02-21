use crate::entry::CacheEntry;

/// An index-based doubly linked list.
///
/// Nodes live inside a `Vec<Option<CacheEntry>>`.  Free slots are
/// tracked in a simple free-list so that indices can be reused after
/// eviction.
pub struct DoublyLinkedList<K: Clone, V: Clone> {
    nodes: Vec<Option<CacheEntry<K, V>>>,
    head: Option<usize>,
    tail: Option<usize>,
    free: Vec<usize>,
    len: usize,
}

impl<K: Clone + std::fmt::Debug, V: Clone + std::fmt::Debug> DoublyLinkedList<K, V> {
    pub fn new() -> Self {
        DoublyLinkedList {
            nodes: Vec::new(),
            head: None,
            tail: None,
            free: Vec::new(),
            len: 0,
        }
    }

    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.len
    }

    /// Allocate a slot for a new entry (reuse a free slot or grow).
    fn alloc_slot(&mut self, entry: CacheEntry<K, V>) -> usize {
        if let Some(idx) = self.free.pop() {
            self.nodes[idx] = Some(entry);
            idx
        } else {
            let idx = self.nodes.len();
            self.nodes.push(Some(entry));
            idx
        }
    }

    /// Insert a new entry at the front of the list.  Returns the slot index.
    pub fn push_front(&mut self, key: K, value: V) -> usize {
        let mut entry = CacheEntry::new(key, value);
        entry.prev = None;
        entry.next = self.head;

        let idx = self.alloc_slot(entry);

        if let Some(old_head) = self.head {
            if let Some(ref mut node) = self.nodes[old_head] {
                node.prev = Some(idx);
            }
        }

        self.head = Some(idx);
        if self.tail.is_none() {
            self.tail = Some(idx);
        }

        self.len += 1;
        idx
    }

    /// Move an existing node to the front of the list.
    pub fn move_to_front(&mut self, idx: usize) {
        if self.head == Some(idx) {
            return; // already at front
        }

        // Detach the node from its current position.
        let (prev, next) = {
            let node = self.nodes[idx].as_ref().unwrap();
            (node.prev, node.next)
        };

        // Link the neighbours together.
        if let Some(p) = prev {
            if let Some(ref mut pn) = self.nodes[p] {
                pn.next = next;
            }
        }
        if let Some(n) = next {
            if let Some(ref mut nn) = self.nodes[n] {
                nn.prev = prev;
            }
        }

        // If this was the tail, update tail pointer.
        if self.tail == Some(idx) {
            self.tail = prev;
        }

        // Attach at front.
        {
            let node = self.nodes[idx].as_mut().unwrap();
            node.prev = None;
            node.next = self.head;
        }

        // BUG: The old head's `prev` pointer is NOT updated to point
        //      back to `idx`.  After several move_to_front calls the
        //      backward chain breaks: traversing from the old head
        //      toward the real head skips the moved node.
        //
        // The fix is:
        //   if let Some(old_head) = self.head {
        //       if let Some(ref mut hn) = self.nodes[old_head] {
        //           hn.prev = Some(idx);
        //       }
        //   }

        self.head = Some(idx);
    }

    /// Remove and return the key of the tail (least-recently-used) entry.
    pub fn remove_tail(&mut self) -> Option<K> {
        let tail_idx = self.tail?;
        self.remove_node(tail_idx)
    }

    /// Remove a node by index and return its key.
    fn remove_node(&mut self, idx: usize) -> Option<K> {
        let node = self.nodes[idx].take()?;
        let prev = node.prev;
        let next = node.next;

        if let Some(p) = prev {
            if let Some(ref mut pn) = self.nodes[p] {
                pn.next = next;
            }
        } else {
            self.head = next;
        }

        if let Some(n) = next {
            if let Some(ref mut nn) = self.nodes[n] {
                nn.prev = prev;
            }
        } else {
            self.tail = prev;
        }

        self.free.push(idx);
        self.len -= 1;
        Some(node.key)
    }

    /// Update the value stored at `idx` without moving it.
    pub fn update_value(&mut self, idx: usize, value: V) {
        if let Some(ref mut node) = self.nodes[idx] {
            node.value = value;
        }
    }

    /// Read the value at `idx`.
    pub fn get_value(&self, idx: usize) -> Option<&V> {
        self.nodes[idx].as_ref().map(|n| &n.value)
    }

    /// Iterate from head to tail (most-recently-used first) for debugging.
    #[allow(dead_code)]
    pub fn iter_forward(&self) -> Vec<(K, V)> {
        let mut result = Vec::new();
        let mut cur = self.head;
        while let Some(idx) = cur {
            if let Some(ref node) = self.nodes[idx] {
                result.push((node.key.clone(), node.value.clone()));
                cur = node.next;
            } else {
                break;
            }
        }
        result
    }
}
