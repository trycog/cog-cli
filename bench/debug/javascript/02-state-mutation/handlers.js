function createHandlerA() {
  return function handleA(event) {
    return {
      handler: 'A',
      receivedKeys: Object.keys(event).sort(),
      amount: event.amount,
    };
  };
}

function createHandlerB() {
  return function handleB(event) {
    return {
      handler: 'B',
      receivedKeys: Object.keys(event).sort(),
      amount: event.amount,
    };
  };
}

module.exports = { createHandlerA, createHandlerB };
