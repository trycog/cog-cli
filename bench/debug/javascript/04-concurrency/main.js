const { RequestCache } = require('./cache');
const { Collector } = require('./collector');
const { processPages } = require('./worker');
const { WorkScheduler } = require('./scheduler');

async function main() {
  const totalItems = 100;
  const pageSize = 10;
  const pageCount = Math.ceil(totalItems / pageSize);

  const cache = new RequestCache();
  const collector = new Collector();
  const workerIds = [1, 2];

  // Create a work plan that partitions pages among responsive workers
  const scheduler = new WorkScheduler(pageCount, workerIds);
  const plan = scheduler.createPlan();

  await Promise.all(
    workerIds.map(id =>
      processPages(id, plan.getPages(id), pageSize, totalItems, cache, collector)
    )
  );

  if (collector.totalItems === collector.uniqueItems && collector.uniqueItems === totalItems) {
    console.log(`Processed ${collector.uniqueItems} unique items`);
  } else {
    console.log(`Processed ${collector.totalItems} items (${collector.uniqueItems} unique)`);
  }
}

main();
