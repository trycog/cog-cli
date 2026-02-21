#ifndef PARSER_H
#define PARSER_H

#include "ast.h"
#include "lexer.h"
#include <vector>

class Parser {
public:
    explicit Parser(const std::vector<Token>& tokens);
    ASTNode* parse();

private:
    std::vector<Token> tokens;
    size_t pos;

    const Token& current() const;
    const Token& advance();
    bool match(TokenType type);

    ASTNode* parseExpression();
    ASTNode* parseTerm();
    ASTNode* parsePrimary();
};

#endif
