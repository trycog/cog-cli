/// A directed, weighted graph stored as an adjacency list.
///
/// Nodes are identified by `usize` indices. Each edge has a `u32` weight.

#[derive(Debug, Clone)]
pub struct Edge {
    pub to: usize,
    pub weight: u32,
}

pub struct Graph {
    adj: Vec<Vec<Edge>>,
    labels: Vec<String>,
}

impl Graph {
    /// Create a new graph with `n` nodes.
    pub fn new(labels: Vec<&str>) -> Self {
        let n = labels.len();
        Graph {
            adj: vec![Vec::new(); n],
            labels: labels.into_iter().map(String::from).collect(),
        }
    }

    /// Add a directed edge from `from` to `to` with the given weight.
    pub fn add_edge(&mut self, from: usize, to: usize, weight: u32) {
        self.adj[from].push(Edge { to, weight });
    }

    /// Return the neighbors of node `u` and their edge weights.
    pub fn neighbors(&self, u: usize) -> &[Edge] {
        &self.adj[u]
    }

    /// Number of nodes.
    pub fn num_nodes(&self) -> usize {
        self.adj.len()
    }

    /// Human-readable label for a node.
    pub fn label(&self, node: usize) -> &str {
        &self.labels[node]
    }

    /// Look up a node index by label (case-sensitive).
    pub fn node_index(&self, label: &str) -> Option<usize> {
        self.labels.iter().position(|l| l == label)
    }
}

/// Build the benchmark graph:
///
/// ```text
///   A --2--> B --1--> D --4--> E
///   A --10-> C --0--> E
/// ```
///
/// Correct shortest path A->E: A -> B -> D -> E  (cost 7)
/// A -> C -> E has cost 10 (suboptimal)
pub fn build_benchmark_graph() -> Graph {
    // Nodes: A=0, B=1, C=2, D=3, E=4
    let mut g = Graph::new(vec!["A", "B", "C", "D", "E"]);

    g.add_edge(0, 1, 2);  // A -> B: 2
    g.add_edge(0, 2, 10); // A -> C: 10
    g.add_edge(1, 3, 1);  // B -> D: 1
    g.add_edge(3, 4, 4);  // D -> E: 4
    g.add_edge(2, 4, 0);  // C -> E: 0

    g
}
