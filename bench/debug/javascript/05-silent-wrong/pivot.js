function pivot(aggregated, columnOrder) {
  const result = {};
  const matched = new Set();

  for (const colName of columnOrder) {
    for (const [key, value] of aggregated) {
      // BUG: key is a NUMBER (from groupBy), colName is a STRING
      // (from the year-strings array). Strict equality (===) never
      // matches because number !== string.
      // Fix: if (String(key) === colName) {
      if (key === colName) {
        result[colName] = value;
        matched.add(key);
        break;
      }
    }
  }

  // Unmatched entries go to "other"
  let other = 0;
  for (const [key, value] of aggregated) {
    if (!matched.has(key)) {
      other += value;
    }
  }

  if (other > 0) {
    result['other'] = other;
  }

  return result;
}

module.exports = { pivot };
