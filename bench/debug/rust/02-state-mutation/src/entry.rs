/// A single entry in the doubly linked list backing the LRU cache.
///
/// Uses `Option<usize>` indices into the node vector rather than raw
/// pointers, keeping the implementation safe Rust.
#[derive(Debug, Clone)]
pub struct CacheEntry<K, V> {
    pub key: K,
    pub value: V,
    pub prev: Option<usize>,
    pub next: Option<usize>,
}

impl<K, V> CacheEntry<K, V> {
    pub fn new(key: K, value: V) -> Self {
        CacheEntry {
            key,
            value,
            prev: None,
            next: None,
        }
    }
}
