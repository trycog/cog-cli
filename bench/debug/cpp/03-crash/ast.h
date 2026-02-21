#ifndef AST_H
#define AST_H

#include <string>

struct ASTNode {
    enum Type { Number, BinaryOp, UnaryOp, Variable };

    Type type;
    double value;
    char op;
    std::string name;
    ASTNode* left;
    ASTNode* right;

    // Number literal
    explicit ASTNode(double val)
        : type(Number), value(val), op(0), left(nullptr), right(nullptr) {}

    // Binary operation
    ASTNode(char op, ASTNode* l, ASTNode* r)
        : type(BinaryOp), value(0), op(op), left(l), right(r) {}

    // Unary operation
    ASTNode(char op, ASTNode* operand)
        : type(UnaryOp), value(0), op(op), left(operand), right(nullptr) {}

    // Variable reference
    explicit ASTNode(const std::string& varName)
        : type(Variable), value(0), op(0), name(varName),
          left(nullptr), right(nullptr) {}

    ~ASTNode() {
        delete left;
        delete right;
    }
};

#endif
