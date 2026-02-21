async function fetchPage(page, pageSize, totalItems) {
  // Simulate network latency
  await new Promise(resolve => setTimeout(resolve, 1 + Math.random() * 3));

  const startId = page * pageSize;
  const items = [];
  for (let i = 0; i < pageSize && startId + i < totalItems; i++) {
    items.push({ id: startId + i, value: `item_${startId + i}` });
  }

  return { page, items };
}

module.exports = { fetchPage };
