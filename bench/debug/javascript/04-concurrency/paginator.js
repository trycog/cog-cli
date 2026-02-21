class AsyncPaginator {
  constructor(totalItems, pageSize) {
    this.totalItems = totalItems;
    this.pageSize = pageSize;
    this.totalPages = Math.ceil(totalItems / pageSize);
    this.currentPage = 0;
  }

  async nextPage() {
    if (this.currentPage >= this.totalPages) {
      return null;
    }

    // BUG: Read the page number before the await, but increment AFTER.
    // When two consumers call nextPage() concurrently, both read the
    // same currentPage value before either increments it, causing
    // duplicate pages. Some pages may also be skipped.
    // Fix: const page = this.currentPage++;  (atomic read+increment before await)
    const page = this.currentPage;

    // Simulate async data fetch — yields control to other consumers
    await new Promise(resolve => setTimeout(resolve, 1));

    this.currentPage++;

    // Generate page data
    const startId = page * this.pageSize;
    const items = [];
    for (let i = 0; i < this.pageSize && startId + i < this.totalItems; i++) {
      items.push({ id: startId + i, value: `item_${startId + i}` });
    }

    return { page, items };
  }

  hasMore() {
    return this.currentPage < this.totalPages;
  }
}

module.exports = { AsyncPaginator };
