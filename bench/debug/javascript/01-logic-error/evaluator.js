function evaluate(node) {
  if (node.type === 'number') {
    return node.value;
  }

  if (node.type === 'unary_minus') {
    return -evaluate(node.left);
  }

  if (node.type === 'binary') {
    const left = evaluate(node.left);
    const right = evaluate(node.right);

    switch (node.value) {
      case '+': return left + right;
      case '-': return left - right;
      case '*': return left * right;
      case '/':
        if (right === 0) throw new Error('Division by zero');
        return left / right;
      case '^': return Math.pow(left, right);
      default: throw new Error(`Unknown operator: ${node.value}`);
    }
  }

  throw new Error(`Unknown node type: ${node.type}`);
}

module.exports = { evaluate };
