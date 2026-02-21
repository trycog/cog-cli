function createTimestampMiddleware(handlerName) {
  return function (event) {
    // BUG: mutates the original event object instead of cloning
    // Fix: const enriched = { ...event };
    const enriched = event;
    enriched[`_timestamp_${handlerName}`] = Date.now();
    enriched._last_processed_by = handlerName;
    return enriched;
  };
}

function createValidationMiddleware() {
  return function (event) {
    // BUG: same issue — mutates original instead of cloning
    // Fix: const validated = { ...event };
    const validated = event;
    validated._validated = true;

    if (typeof event.amount === 'number' && event.amount < 0) {
      validated._validation_error = 'Negative amount';
    }

    return validated;
  };
}

function createLoggingMiddleware(handlerName) {
  return function (event) {
    // BUG: same issue — mutates original instead of cloning
    // Fix: const logged = { ...event };
    const logged = event;
    if (!logged._processing_log) {
      logged._processing_log = [];
    }
    logged._processing_log.push(handlerName);
    return logged;
  };
}

module.exports = { createTimestampMiddleware, createValidationMiddleware, createLoggingMiddleware };
