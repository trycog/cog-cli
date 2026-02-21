function createHandlerA() {
  return function handleA(event) {
    return {
      handler: 'A',
      amount: event.amount,
      timestamps: Object.keys(event.metadata.timestamps),
      lastProcessor: event.metadata.lastProcessor,
    };
  };
}

function createHandlerB() {
  return function handleB(event) {
    return {
      handler: 'B',
      amount: event.amount,
      timestamps: Object.keys(event.metadata.timestamps),
      lastProcessor: event.metadata.lastProcessor,
      logEntries: [...event.metadata.log],
    };
  };
}

module.exports = { createHandlerA, createHandlerB };
