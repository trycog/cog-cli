const { fetchPage } = require('./api');

async function processPages(workerId, pages, pageSize, totalItems, cache, collector) {
  for (const page of pages) {
    const result = await cache.fetch(
      `page-${page}`,
      () => fetchPage(page, pageSize, totalItems)
    );
    collector.add(result.items, `worker-${workerId}`);
  }
}

module.exports = { processPages };
