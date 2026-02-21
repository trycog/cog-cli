class Processor {
  constructor() {
    this.items = [];
    this.seenIds = new Set();
  }

  addItems(items) {
    for (const item of items) {
      this.items.push(item);
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

module.exports = { Processor };
