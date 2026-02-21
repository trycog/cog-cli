#ifndef BST_H
#define BST_H

#include "node.h"
#include <vector>

class BST {
public:
    BST();
    ~BST();

    void insert(int key);
    void remove(int key);
    bool find(int key) const;
    std::vector<int> inorder() const;

private:
    Node* root;

    Node* insertHelper(Node* node, int key);
    Node* removeHelper(Node* node, int key);
    Node* findMin(Node* node) const;
    bool findHelper(Node* node, int key) const;
    void inorderHelper(Node* node, std::vector<int>& result) const;
    void destroyTree(Node* node);
};

#endif
