// Explore benchmark results — fill in after running prompts
// Open dashboard.html to visualize
const EXPLORE_DATA = {
  model: "",
  date: "",
  languages: [
    {
      name: "React", language: "javascript",
      results: [
        { name: "Architecture: reconciliation", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Pattern: adding a new hook", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Error boundaries", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Fiber scheduler & lanes", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Event system debugging", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
      ]
    },
    {
      name: "Gin", language: "go",
      results: [
        { name: "Architecture: request flow", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Pattern: custom middleware", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Routing internals", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "JSON binding & validation", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Panic recovery", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
      ]
    },
    {
      name: "Flask", language: "python",
      results: [
        { name: "Architecture: request context", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Pattern: blueprints", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "URL routing & dispatch", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Error handling", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Response system", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
      ]
    },
    {
      name: "ripgrep", language: "rust",
      results: [
        { name: "Architecture: search pipeline", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Pattern: output formats", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "File filtering & ignore", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Parallelism model", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
        { name: "Modification: new output format", explore: { calls: 0, rounds: 0, pass: false }, traditional: { calls: 0, rounds: 0, pass: false } },
      ]
    },
  ]
};
