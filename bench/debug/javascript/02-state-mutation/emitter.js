class EventEmitter {
  constructor() {
    this.handlers = [];
  }

  on(eventType, handler, middleware = []) {
    this.handlers.push({ eventType, handler, middleware });
  }

  emit(eventType, eventData) {
    const results = [];

    for (const registration of this.handlers) {
      if (registration.eventType !== eventType) continue;

      // Apply middleware chain to the event
      let processedEvent = eventData;
      for (const mw of registration.middleware) {
        processedEvent = mw(processedEvent);
      }

      const result = registration.handler(processedEvent);
      results.push(result);
    }

    return results;
  }
}

module.exports = { EventEmitter };
