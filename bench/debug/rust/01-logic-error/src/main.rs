mod heap;
mod priority_queue;
mod graph;

use priority_queue::MinPriorityQueue;
use graph::{build_benchmark_graph, Graph};

/// Run Dijkstra's shortest-path algorithm from `source` to `target`.
///
/// Returns `(cost, path)` where `path` is a vector of node indices
/// from source to target (inclusive).  Returns `None` if unreachable.
fn dijkstra(graph: &Graph, source: usize, target: usize) -> Option<(u32, Vec<usize>)> {
    let n = graph.num_nodes();
    let mut dist = vec![u32::MAX; n];
    let mut prev: Vec<Option<usize>> = vec![None; n];
    let mut visited = vec![false; n];

    let mut pq = MinPriorityQueue::new(n);

    dist[source] = 0;
    pq.insert(source, 0);

    while let Some(entry) = pq.extract_min() {
        let u = entry.item;
        let cost_u = entry.priority;

        // Early termination: target reached.
        if u == target {
            return Some((cost_u, reconstruct_path(&prev, source, target)));
        }

        if visited[u] {
            continue;
        }
        visited[u] = true;

        // Skip stale entries whose distance was already improved.
        if cost_u > dist[u] {
            continue;
        }

        for edge in graph.neighbors(u) {
            let v = edge.to;
            let new_dist = cost_u.saturating_add(edge.weight);

            if new_dist < dist[v] {
                dist[v] = new_dist;
                prev[v] = Some(u);

                if pq.contains(v) {
                    pq.decrease_key(v, new_dist);
                } else {
                    pq.insert(v, new_dist);
                }
            }
        }
    }

    // Target was never extracted — unreachable.
    if dist[target] == u32::MAX {
        None
    } else {
        Some((dist[target], reconstruct_path(&prev, source, target)))
    }
}

/// Walk the predecessor chain from target back to source.
fn reconstruct_path(prev: &[Option<usize>], source: usize, target: usize) -> Vec<usize> {
    let mut path = Vec::new();
    let mut current = target;

    loop {
        path.push(current);
        if current == source {
            break;
        }
        match prev[current] {
            Some(p) => current = p,
            None => break, // no path
        }
    }

    path.reverse();
    path
}

/// Pretty-print a path using the graph's node labels.
fn format_path(graph: &Graph, path: &[usize]) -> String {
    path.iter()
        .map(|&n| graph.label(n).to_string())
        .collect::<Vec<_>>()
        .join(" -> ")
}

fn main() {
    let graph = build_benchmark_graph();

    let source = graph.node_index("A").expect("Node A not found");
    let target = graph.node_index("E").expect("Node E not found");

    match dijkstra(&graph, source, target) {
        Some((cost, path)) => {
            let path_str = format_path(&graph, &path);
            println!("Shortest A->E: cost {}, path {}", cost, path_str);
        }
        None => {
            println!("No path from A to E");
        }
    }
}
