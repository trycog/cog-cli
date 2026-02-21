const { ResourcePool } = require('./pool');

async function main() {
  let errorCount = 0;

  const pool = new ResourcePool(3, {
    // onError callback releases the resource to "reclaim" it on failure.
    // But pool.execute() ALSO calls release() in its catch block,
    // causing a double-release. The second release hits indexOf === -1,
    // and splice(-1, 1) removes the last element from inUse — a
    // completely unrelated resource — corrupting the pool.
    onError: (err, resource, pool) => {
      errorCount++;
      pool.release(resource);
    },
  });

  const tasks = [];
  let completed = 0;
  let failed = 0;

  for (let i = 0; i < 50; i++) {
    const task = pool.execute(async (resource) => {
      // Simulate work with occasional failures
      const delay = (i % 5) + 1;
      await new Promise(resolve => setTimeout(resolve, delay));

      if (i % 7 === 0) {
        throw new Error(`Operation ${i} failed on ${resource}`);
      }

      return { op: i, resource: resource.id };
    }).then(() => {
      completed++;
    }).catch(() => {
      failed++;
    });

    tasks.push(task);
  }

  await Promise.all(tasks);

  const stats = pool.stats;
  const totalTracked = stats.available + stats.inUse + stats.waiting;

  if (totalTracked === stats.total) {
    console.log(`Pool intact: ${completed} completed, ${failed} failed, ${stats.total} resources tracked`);
  } else {
    console.log(`Pool corrupted: ${completed} completed, ${failed} failed, expected ${stats.total} resources but tracking ${totalTracked}`);
  }
}

main();
