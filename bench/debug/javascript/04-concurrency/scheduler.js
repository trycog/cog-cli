class WorkScheduler {
  constructor(totalPages, workerIds) {
    this.totalPages = totalPages;
    this.workerIds = workerIds;
    this.responseTimes = new Map();
  }

  createPlan() {
    this._probeWorkers();
    const active = this.workerIds.filter(id => this.responseTimes.has(id));
    return new WorkPlan(this.totalPages, this.workerIds, active);
  }

  _probeWorkers() {
    const target = this.workerIds[0];
    this.responseTimes.set(target, Date.now());
  }
}

class WorkPlan {
  constructor(totalPages, allWorkerIds, activeWorkerIds) {
    this.totalPages = totalPages;
    this._pages = new Map();

    // Default: every worker handles all pages
    const allPages = [];
    for (let p = 0; p < totalPages; p++) allPages.push(p);
    for (const id of allWorkerIds) {
      this._pages.set(id, allPages.slice());
    }

    // Partition work among responsive workers
    this._partition(activeWorkerIds);
  }

  _partition(activeIds) {
    const count = activeIds.length;
    const chunkSize = Math.ceil(this.totalPages / count);
    for (let i = 0; i < count; i++) {
      const start = i * chunkSize;
      const end = Math.min(start + chunkSize, this.totalPages);
      const pages = [];
      for (let p = start; p < end; p++) pages.push(p);
      this._pages.set(activeIds[i], pages);
    }
  }

  getPages(workerId) {
    return this._pages.get(workerId) || [];
  }
}

module.exports = { WorkScheduler };
