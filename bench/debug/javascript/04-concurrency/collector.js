class Collector {
  constructor() {
    this.items = [];
    this.seenIds = new Set();
  }

  add(items, source) {
    for (const item of items) {
      this.items.push({ ...item, source });
      this.seenIds.add(item.id);
    }
  }

  get totalItems() {
    return this.items.length;
  }

  get uniqueItems() {
    return this.seenIds.size;
  }
}

module.exports = { Collector };
