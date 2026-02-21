const { AsyncPaginator } = require('./paginator');
const { fetchPage } = require('./fetcher');
const { Processor } = require('./processor');

async function consume(paginator, processor, name) {
  while (true) {
    const result = await fetchPage(paginator);
    if (!result) break;
    processor.addItems(result.items);
  }
}

async function main() {
  const paginator = new AsyncPaginator(100, 10); // 100 items, 10 per page
  const processor = new Processor();

  // Two concurrent consumers sharing the same paginator
  await Promise.all([
    consume(paginator, processor, 'consumer-1'),
    consume(paginator, processor, 'consumer-2'),
  ]);

  if (processor.totalItems === processor.uniqueItems && processor.uniqueItems === 100) {
    console.log(`Processed ${processor.uniqueItems} unique items`);
  } else {
    console.log(`Processed ${processor.totalItems} items (${processor.uniqueItems} unique)`);
  }
}

main();
