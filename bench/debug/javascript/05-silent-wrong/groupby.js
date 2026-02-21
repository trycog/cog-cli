function groupBy(dataframe, keyColumn, valueColumn) {
  const keyIdx = dataframe.columns.indexOf(keyColumn);
  const valIdx = dataframe.columns.indexOf(valueColumn);

  if (keyIdx === -1 || valIdx === -1) {
    throw new Error(`Column not found: ${keyColumn} or ${valueColumn}`);
  }

  const groups = new Map();

  for (const row of dataframe.rows) {
    const key = row[keyIdx]; // This is a NUMBER (e.g., 2021)
    const value = row[valIdx];

    if (!groups.has(key)) {
      groups.set(key, []);
    }
    groups.get(key).push(value);
  }

  return groups;
}

module.exports = { groupBy };
