const contexts = new Map();

function getOrCreateContext(type) {
  if (!contexts.has(type)) {
    contexts.set(type, { timestamps: {}, log: [] });
  }
  return contexts.get(type);
}

function createTimestampMiddleware(handlerName) {
  const ctx = getOrCreateContext('timestamp');
  return function (event) {
    ctx.timestamps[handlerName] = Date.now();
    return {
      ...event,
      metadata: {
        ...event.metadata,
        timestamps: { ...ctx.timestamps },
        lastProcessor: handlerName,
      },
    };
  };
}

function createValidationMiddleware() {
  const ctx = getOrCreateContext('validation');
  return function (event) {
    const result = {
      ...event,
      metadata: { ...event.metadata, validated: true },
    };
    if (typeof event.amount === 'number' && event.amount < 0) {
      result.metadata.validationError = 'Negative amount';
    }
    return result;
  };
}

function createLoggingMiddleware(handlerName) {
  const ctx = getOrCreateContext('logging');
  return function (event) {
    ctx.log.push(handlerName);
    return {
      ...event,
      metadata: { ...event.metadata, log: [...ctx.log] },
    };
  };
}

module.exports = { createTimestampMiddleware, createValidationMiddleware, createLoggingMiddleware };
