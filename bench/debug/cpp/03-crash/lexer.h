#ifndef LEXER_H
#define LEXER_H

#include <string>
#include <vector>

enum class TokenType {
    Number,
    Plus,
    Minus,
    Star,
    Slash,
    LParen,
    RParen,
    End
};

struct Token {
    TokenType type;
    std::string text;
    double numValue;

    Token(TokenType t, const std::string& txt, double val = 0)
        : type(t), text(txt), numValue(val) {}
};

class Lexer {
public:
    explicit Lexer(const std::string& input);
    std::vector<Token> tokenize();

private:
    std::string input;
    size_t pos;

    Token nextToken();
    void skipWhitespace();
};

#endif
