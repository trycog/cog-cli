class WaitQueue {
  constructor() {
    this.waiting = [];
  }

  enqueue() {
    return new Promise((resolve) => {
      this.waiting.push(resolve);
    });
  }

  dequeue() {
    if (this.waiting.length > 0) {
      const resolve = this.waiting.shift();
      return resolve;
    }
    return null;
  }

  get length() {
    return this.waiting.length;
  }
}

module.exports = { WaitQueue };
