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
    pub fn new(labels: Vec<&str>) -> Self {
        let n = labels.len();
        Graph {
            adj: vec![Vec::new(); n],
            labels: labels.into_iter().map(String::from).collect(),
        }
    }

    pub fn add_edge(&mut self, from: usize, to: usize, weight: u32) {
        self.adj[from].push(Edge { to, weight });
    }

    pub fn neighbors(&self, u: usize) -> &[Edge] {
        &self.adj[u]
    }

    pub fn num_nodes(&self) -> usize {
        self.adj.len()
    }

    pub fn label(&self, node: usize) -> &str {
        &self.labels[node]
    }

    pub fn node_index(&self, label: &str) -> Option<usize> {
        self.labels.iter().position(|l| l == label)
    }
}

/// Add an edge between two nodes.
fn connect(g: &mut Graph, endpoints: (usize, usize), weight: u32) {
    g.add_edge(endpoints.0, endpoints.1, weight);
}

/// Build the benchmark graph:
///
/// ```text
///   A --2-- B --1-- D --4-- E
///   |                       |
///   +--10-- C ------0-------+
/// ```
///
/// Shortest path A→E: cost 7 via A→B→D→E
pub fn build_benchmark_graph() -> Graph {
    // Nodes: A=0, B=1, C=2, D=3, E=4
    let mut g = Graph::new(vec!["A", "B", "C", "D", "E"]);

    connect(&mut g, (0, 1), 2);   // A -- B : 2
    connect(&mut g, (0, 2), 10);  // A -- C : 10
    connect(&mut g, (3, 1), 1);   // B -- D : 1
    connect(&mut g, (3, 4), 4);   // D -- E : 4
    connect(&mut g, (2, 4), 0);   // C -- E : 0

    g
}
