#include "parser.h"
#include <stdexcept>

Parser::Parser(const std::vector<Token>& tokens) : tokens(tokens), pos(0) {}

const Token& Parser::current() const {
    return tokens[pos];
}

const Token& Parser::advance() {
    const Token& tok = tokens[pos];
    if (pos < tokens.size() - 1) pos++;
    return tok;
}

bool Parser::match(TokenType type) {
    if (current().type == type) {
        advance();
        return true;
    }
    return false;
}

// Parse an additive expression: term (('+' | '-') term)*
ASTNode* Parser::parseExpression() {
    ASTNode* left = parseTerm();

    while (current().type == TokenType::Plus ||
           current().type == TokenType::Minus) {
        char op = (current().type == TokenType::Plus) ? '+' : '-';
        advance();
        ASTNode* right = parseTerm();
        left = new ASTNode(op, left, right);
    }

    return left;
}

// Parse a multiplicative expression: primary (('*' | '/') primary)*
//
// BUG: When the left operand is a unary minus node (e.g., from parsing
// "-(3+4)"), this function attempts an "optimization" that extracts the
// inner operand from the unary node, deletes the unary wrapper, and
// negates the inner node's value field. But the inner node is a BinaryOp
// (3+4), not a Number, so setting its value field does nothing useful.
// Worse, deleting the unary wrapper triggers its destructor, which
// recursively deletes its child (the inner BinaryOp). The local pointer
// to the inner node is now dangling. Using it as the left operand of
// the multiplication creates a use-after-free, leading to a crash when
// the evaluator traverses the freed node.
ASTNode* Parser::parseTerm() {
    ASTNode* left = parsePrimary();

    while (current().type == TokenType::Star ||
           current().type == TokenType::Slash) {
        char op = (current().type == TokenType::Star) ? '*' : '/';
        advance();

        // BUG: Attempt to "optimize" unary minus by folding it into
        // the multiplication. Setting value on a BinaryOp node does
        // nothing — the negation is silently lost.
        if (left->type == ASTNode::UnaryOp && left->op == '-') {
            ASTNode* inner = left->left;
            left->left = nullptr;
            delete left;
            inner->value = -inner->value;
            left = inner;
        }

        ASTNode* right = parsePrimary();
        left = new ASTNode(op, left, right);
    }

    return left;
}

// Parse a primary: number, unary minus, or parenthesized expression
ASTNode* Parser::parsePrimary() {
    // Unary minus
    if (current().type == TokenType::Minus) {
        advance();
        ASTNode* operand = parsePrimary();
        return new ASTNode('-', operand);
    }

    // Parenthesized expression
    if (current().type == TokenType::LParen) {
        advance();
        ASTNode* expr = parseExpression();
        if (!match(TokenType::RParen)) {
            throw std::runtime_error("Expected closing parenthesis");
        }
        return expr;
    }

    // Number literal
    if (current().type == TokenType::Number) {
        double val = current().numValue;
        advance();
        return new ASTNode(val);
    }

    throw std::runtime_error(
        "Unexpected token: " + current().text);
}

ASTNode* Parser::parse() {
    ASTNode* result = parseExpression();
    if (current().type != TokenType::End) {
        throw std::runtime_error(
            "Unexpected token after expression: " + current().text);
    }
    return result;
}
