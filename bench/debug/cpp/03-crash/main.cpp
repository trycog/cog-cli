#include "ast.h"
#include "lexer.h"
#include "parser.h"
#include <iostream>
#include <string>

// Defined in evaluator.cpp
double evaluate(ASTNode* node);

void evalAndPrint(const std::string& expr) {
    try {
        Lexer lexer(expr);
        auto tokens = lexer.tokenize();
        Parser parser(tokens);
        ASTNode* ast = parser.parse();
        double result = evaluate(ast);
        std::cout << expr << " = " << result << std::endl;
        delete ast;
    } catch (const std::exception& e) {
        std::cout << expr << " => ERROR: " << e.what() << std::endl;
    }
}

int main() {
    // These expressions work fine (no unary minus before multiplication)
    evalAndPrint("3 + 4");
    evalAndPrint("(3 + 4) * 2");
    evalAndPrint("10 / (2 + 3)");

    // This expression triggers the use-after-free crash:
    // Parser sees unary minus, creates UnaryOp('-', BinaryOp(3,+,4)).
    // Then parseTerm sees '*', hits the buggy "optimization" that deletes
    // the unary node (which also frees the BinaryOp child), then uses
    // the freed BinaryOp as a multiplication operand.
    evalAndPrint("-(3 + 4) * 2");

    return 0;
}
