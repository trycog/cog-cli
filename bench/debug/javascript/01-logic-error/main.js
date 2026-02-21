const { tokenize } = require('./tokenizer');
const { Parser } = require('./parser');
const { evaluate } = require('./evaluator');

function calc(expression) {
  const tokens = tokenize(expression);
  const parser = new Parser(tokens);
  const ast = parser.parse();
  return evaluate(ast);
}

// Test right-associativity of exponentiation
// 2^3^2 should be 2^(3^2) = 2^9 = 512 (right-associative)
// Bug makes it (2^3)^2 = 8^2 = 64 (left-associative)
const expr = '2^3^2';
const result = calc(expr);
console.log(`${expr} = ${result}`);
