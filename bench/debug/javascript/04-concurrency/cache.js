class RequestCache {
  constructor() {
    this.results = new Map();
    this.pending = new Map();
  }

  async fetch(key, loader) {
    // Return cached result if available
    if (this.results.has(key)) {
      return this.results.get(key);
    }

    // Coalesce concurrent requests for the same key
    if (this.pending.has(key)) {
      return this.pending.get(key);
    }

    // First request for this key — execute and cache
    const promise = loader().then(result => {
      this.results.set(key, result);
      this.pending.delete(key);
      return result;
    });

    this.pending.set(key, promise);
    return promise;
  }

  get hits() {
    return this.results.size;
  }
}

module.exports = { RequestCache };
