function aggregate(groups, fn) {
  const result = new Map();
  for (const [key, values] of groups) {
    result.set(key, fn(values));
  }
  return result;
}

module.exports = { aggregate };
