const { EventEmitter } = require('./emitter');
const { createTimestampMiddleware, createValidationMiddleware, createLoggingMiddleware } = require('./middleware');
const { createHandlerA, createHandlerB } = require('./handlers');

function main() {
  const emitter = new EventEmitter();

  // Handler A with its middleware chain
  emitter.on('order', createHandlerA(), [
    createValidationMiddleware(),
    createTimestampMiddleware('A'),
    createLoggingMiddleware('A'),
  ]);

  // Handler B with its own middleware chain
  // Should receive a clean event, not one polluted by A's middleware
  emitter.on('order', createHandlerB(), [
    createValidationMiddleware(),
    createTimestampMiddleware('B'),
    createLoggingMiddleware('B'),
  ]);

  // Emit an event with nested metadata
  const event = {
    type: 'order',
    amount: 100,
    item: 'Widget',
    metadata: { timestamps: {}, log: [], validated: false, lastProcessor: null },
  };
  const results = emitter.emit('order', event);

  // Check if handler B's metadata was contaminated by handler A's middleware
  const bResult = results[1];
  const hasLeakedTimestamps = bResult.timestamps.some(t => t === 'A');
  const hasLeakedLog = bResult.logEntries.some(e => e === 'A');

  if (hasLeakedTimestamps || hasLeakedLog) {
    console.log(`FAIL: Handler B received cross-handler leakage (timestamps: [${bResult.timestamps}], log: [${bResult.logEntries}])`);
  } else {
    console.log('OK: Handler B received clean event, no cross-handler leakage');
  }
}

main();
