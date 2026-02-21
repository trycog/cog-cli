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
  // Should receive a CLEAN event, not one polluted by A's middleware
  emitter.on('order', createHandlerB(), [
    createValidationMiddleware(),
    createTimestampMiddleware('B'),
    createLoggingMiddleware('B'),
  ]);

  // Emit an event
  const event = { type: 'order', amount: 100, item: 'Widget' };
  const results = emitter.emit('order', event);

  // Check if handler B's event was contaminated by handler A's middleware
  const bResult = results[1];
  const leakedKeys = bResult.receivedKeys.filter(k => k.includes('_A'));

  if (leakedKeys.length > 0) {
    console.log(`FAIL: Handler B received ${bResult.receivedKeys.length} keys (leaked: ${leakedKeys.join(', ')})`);
  } else {
    console.log(`OK: Handler B received ${bResult.receivedKeys.length} keys, no leakage`);
  }
}

main();
