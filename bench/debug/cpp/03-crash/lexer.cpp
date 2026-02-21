#include "lexer.h"
#include <cctype>
#include <stdexcept>

Lexer::Lexer(const std::string& input) : input(input), pos(0) {}

void Lexer::skipWhitespace() {
    while (pos < input.size() && std::isspace(input[pos])) {
        pos++;
    }
}

Token Lexer::nextToken() {
    skipWhitespace();

    if (pos >= input.size()) {
        return Token(TokenType::End, "", 0);
    }

    char c = input[pos];

    if (std::isdigit(c) || c == '.') {
        size_t start = pos;
        while (pos < input.size() && (std::isdigit(input[pos]) || input[pos] == '.')) {
            pos++;
        }
        std::string numStr = input.substr(start, pos - start);
        return Token(TokenType::Number, numStr, std::stod(numStr));
    }

    pos++;
    switch (c) {
        case '+': return Token(TokenType::Plus, "+");
        case '-': return Token(TokenType::Minus, "-");
        case '*': return Token(TokenType::Star, "*");
        case '/': return Token(TokenType::Slash, "/");
        case '(': return Token(TokenType::LParen, "(");
        case ')': return Token(TokenType::RParen, ")");
        default:
            throw std::runtime_error(
                std::string("Unexpected character: ") + c);
    }
}

std::vector<Token> Lexer::tokenize() {
    std::vector<Token> tokens;
    while (true) {
        Token tok = nextToken();
        tokens.push_back(tok);
        if (tok.type == TokenType::End) break;
    }
    return tokens;
}
