const TOKEN_TYPES = {
  NUMBER: 'NUMBER',
  PLUS: 'PLUS',
  MINUS: 'MINUS',
  STAR: 'STAR',
  SLASH: 'SLASH',
  CARET: 'CARET',
  LPAREN: 'LPAREN',
  RPAREN: 'RPAREN',
  EOF: 'EOF',
};

class Token {
  constructor(type, value) {
    this.type = type;
    this.value = value;
  }
}

function tokenize(expression) {
  const tokens = [];
  let i = 0;

  while (i < expression.length) {
    const ch = expression[i];

    if (ch === ' ' || ch === '\t') {
      i++;
      continue;
    }

    if ((ch >= '0' && ch <= '9') || ch === '.') {
      let num = '';
      while (i < expression.length && ((expression[i] >= '0' && expression[i] <= '9') || expression[i] === '.')) {
        num += expression[i];
        i++;
      }
      tokens.push(new Token(TOKEN_TYPES.NUMBER, parseFloat(num)));
      continue;
    }

    const ops = {
      '+': TOKEN_TYPES.PLUS,
      '-': TOKEN_TYPES.MINUS,
      '*': TOKEN_TYPES.STAR,
      '/': TOKEN_TYPES.SLASH,
      '^': TOKEN_TYPES.CARET,
      '(': TOKEN_TYPES.LPAREN,
      ')': TOKEN_TYPES.RPAREN,
    };

    if (ops[ch]) {
      tokens.push(new Token(ops[ch], ch));
      i++;
    } else {
      throw new Error(`Unexpected character: '${ch}' at position ${i}`);
    }
  }

  tokens.push(new Token(TOKEN_TYPES.EOF, null));
  return tokens;
}

module.exports = { tokenize, Token, TOKEN_TYPES };
