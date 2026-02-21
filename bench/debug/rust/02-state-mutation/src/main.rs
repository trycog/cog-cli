mod entry;
mod lru;
mod cache;

use cache::LRUCache;

/// Run a scripted access pattern and track cache correctness.
///
/// The pattern is designed to exercise `move_to_front` repeatedly so
/// that the missing `prev` pointer update in `DoublyLinkedList` corrupts
/// the backward chain and causes incorrect evictions.
fn main() {
    let mut cache: LRUCache<&str, i32> = LRUCache::new(4);

    let mut hits = 0u32;
    let mut misses = 0u32;
    let mut errors = 0u32;

    // Helper closure would be nice but we need mutable borrows, so
    // we'll use a macro instead.
    macro_rules! expect_hit {
        ($cache:expr, $key:expr, $expected:expr, $hits:expr, $errors:expr) => {
            match $cache.get(&$key) {
                Some(&v) if v == $expected => $hits += 1,
                Some(&v) => {
                    eprintln!("ERROR: get({}) returned {} (expected {})", $key, v, $expected);
                    $errors += 1;
                }
                None => {
                    eprintln!("ERROR: get({}) returned None (expected {})", $key, $expected);
                    $errors += 1;
                }
            }
        };
    }

    macro_rules! expect_miss {
        ($cache:expr, $key:expr, $misses:expr, $errors:expr) => {
            match $cache.get(&$key) {
                None => $misses += 1,
                Some(&v) => {
                    eprintln!("ERROR: {} should have been evicted, got {}", $key, v);
                    $errors += 1;
                }
            }
        };
    }

    // --- Phase 1: cold fill ---
    // These are put() calls, not counted as hits or misses.
    cache.put("A", 1);
    cache.put("B", 2);
    cache.put("C", 3);
    cache.put("D", 4);
    // List order (MRU first): D C B A

    // --- Phase 2: hit A, B, C to reorder (3 hits) ---
    expect_hit!(cache, "A", 1, hits, errors);
    expect_hit!(cache, "B", 2, hits, errors);
    expect_hit!(cache, "C", 3, hits, errors);
    // Correct order: C B A D
    // With bug: backward chain is corrupted.

    // --- Phase 3: hit D to move it to front (1 hit) ---
    expect_hit!(cache, "D", 4, hits, errors);
    // Correct order: D C B A

    // --- Phase 4: insert E — should evict LRU (A) ---
    cache.put("E", 5);
    // Correct order: E D C B  (A evicted)

    // --- Phase 5: verify A is gone (1 miss), B still here (1 hit) ---
    expect_miss!(cache, "A", misses, errors);
    expect_hit!(cache, "B", 2, hits, errors);

    // --- Phase 6: access C, D, E (3 hits) ---
    expect_hit!(cache, "C", 3, hits, errors);
    expect_hit!(cache, "D", 4, hits, errors);
    expect_hit!(cache, "E", 5, hits, errors);

    // --- Phase 7: insert F, G — two evictions ---
    cache.put("F", 6);
    cache.put("G", 7);
    // After phase 6 accesses order was: E D C B
    // Insert F: evict B (LRU). Order: F E D C
    // Insert G: evict C (LRU). Order: G F E D

    // --- Phase 8: verify recent entries survive (4 hits) ---
    expect_hit!(cache, "G", 7, hits, errors);
    expect_hit!(cache, "F", 6, hits, errors);
    expect_hit!(cache, "E", 5, hits, errors);
    expect_hit!(cache, "D", 4, hits, errors);

    // --- Phase 9: reinsert A (evicts LRU), then access (3 hits) ---
    // Order after phase 8: D E F G
    // Insert A: evict G (LRU). Order: A D E F
    cache.put("A", 10);

    expect_hit!(cache, "A", 10, hits, errors);
    expect_hit!(cache, "D", 4, hits, errors);
    expect_hit!(cache, "E", 5, hits, errors);

    // --- Phase 10: verify evicted entries are gone (3 misses) ---
    expect_miss!(cache, "B", misses, errors);
    expect_miss!(cache, "C", misses, errors);
    expect_miss!(cache, "G", misses, errors);

    // Summary (correct implementation):
    //   hits:   3 + 1 + 1 + 3 + 4 + 3 = 15
    //   misses: 1 + 3 = 4
    //   errors: 0
    //
    // With the bug, some entries are wrongly evicted or still present
    // when they should be gone, flipping hits to errors and misses to errors.
    println!("Cache test: {} hits, {} misses, {} errors", hits, misses, errors);
}
