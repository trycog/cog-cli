function sum(values) {
  return values.reduce((a, b) => a + b, 0);
}

function aggregate(groups, fn) {
  const result = new Map();
  for (const [key, values] of groups) {
    result.set(key, fn(values));
  }
  return result;
}

module.exports = { sum, aggregate };
