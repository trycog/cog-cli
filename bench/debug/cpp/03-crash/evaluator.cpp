#include "ast.h"
#include <stdexcept>
#include <cmath>

double evaluate(ASTNode* node) {
    if (!node) {
        throw std::runtime_error("Null AST node during evaluation");
    }

    switch (node->type) {
        case ASTNode::Number:
            return node->value;

        case ASTNode::UnaryOp:
            if (node->op == '-') {
                return -evaluate(node->left);
            }
            throw std::runtime_error(
                std::string("Unknown unary operator: ") + node->op);

        case ASTNode::BinaryOp: {
            double lhs = evaluate(node->left);
            double rhs = evaluate(node->right);
            switch (node->op) {
                case '+': return lhs + rhs;
                case '-': return lhs - rhs;
                case '*': return lhs * rhs;
                case '/':
                    if (std::abs(rhs) < 1e-12)
                        throw std::runtime_error("Division by zero");
                    return lhs / rhs;
                default:
                    throw std::runtime_error(
                        std::string("Unknown binary operator: ") + node->op);
            }
        }

        default:
            throw std::runtime_error("Unknown AST node type");
    }
}
