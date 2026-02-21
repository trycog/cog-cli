const { TOKEN_TYPES } = require('./tokenizer');

const PRECEDENCE = {
  [TOKEN_TYPES.PLUS]: 1,
  [TOKEN_TYPES.MINUS]: 1,
  [TOKEN_TYPES.STAR]: 2,
  [TOKEN_TYPES.SLASH]: 2,
  [TOKEN_TYPES.CARET]: 3,
};

const RIGHT_ASSOCIATIVE = new Set([TOKEN_TYPES.CARET]);

class ASTNode {
  constructor(type, value, left, right) {
    this.type = type;
    this.value = value;
    this.left = left || null;
    this.right = right || null;
  }
}

class Parser {
  constructor(tokens) {
    this.tokens = tokens;
    this.pos = 0;
  }

  current() {
    return this.tokens[this.pos];
  }

  consume(expectedType) {
    const token = this.current();
    if (expectedType && token.type !== expectedType) {
      throw new Error(`Expected ${expectedType} but got ${token.type}`);
    }
    this.pos++;
    return token;
  }

  parseExpression(minPrec = 0) {
    let left = this.parseAtom();

    while (
      this.current().type !== TOKEN_TYPES.EOF &&
      this.current().type !== TOKEN_TYPES.RPAREN &&
      PRECEDENCE[this.current().type] !== undefined &&
      PRECEDENCE[this.current().type] >= minPrec
    ) {
      const op = this.consume();
      const prec = PRECEDENCE[op.type];

      // BUG: For right-associative operators like ^, we should use `prec`
      // (same precedence) so that the recursive call consumes the rest of
      // the chain. Using `prec + 1` forces left-associative grouping.
      // Fix: const nextMinPrec = RIGHT_ASSOCIATIVE.has(op.type) ? prec : prec + 1;
      const nextMinPrec = prec + 1;

      const right = this.parseExpression(nextMinPrec);
      left = new ASTNode('binary', op.value, left, right);
    }

    return left;
  }

  parseAtom() {
    const token = this.current();

    if (token.type === TOKEN_TYPES.NUMBER) {
      this.consume();
      return new ASTNode('number', token.value);
    }

    if (token.type === TOKEN_TYPES.LPAREN) {
      this.consume(TOKEN_TYPES.LPAREN);
      const expr = this.parseExpression(0);
      this.consume(TOKEN_TYPES.RPAREN);
      return expr;
    }

    if (token.type === TOKEN_TYPES.MINUS) {
      this.consume();
      const operand = this.parseAtom();
      return new ASTNode('unary_minus', '-', operand);
    }

    throw new Error(`Unexpected token: ${token.type}`);
  }

  parse() {
    const ast = this.parseExpression(0);
    if (this.current().type !== TOKEN_TYPES.EOF) {
      throw new Error(`Unexpected token after expression: ${this.current().type}`);
    }
    return ast;
  }
}

module.exports = { Parser, ASTNode };
