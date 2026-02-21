let nextId = 1;

class Resource {
  constructor() {
    this.id = nextId++;
    this.busy = false;
    this.useCount = 0;
  }

  async execute(operation) {
    this.busy = true;
    this.useCount++;
    try {
      const result = await operation(this);
      return result;
    } finally {
      this.busy = false;
    }
  }

  toString() {
    return `Resource#${this.id}`;
  }
}

module.exports = { Resource };
