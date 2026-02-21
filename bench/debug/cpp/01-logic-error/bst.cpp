#include "bst.h"

BST::BST() : root(nullptr) {}

BST::~BST() {
    destroyTree(root);
}

void BST::destroyTree(Node* node) {
    if (node) {
        destroyTree(node->left);
        destroyTree(node->right);
        delete node;
    }
}

Node* BST::insertHelper(Node* node, int key) {
    if (!node) return new Node(key);
    if (key < node->key)
        node->left = insertHelper(node->left, key);
    else if (key > node->key)
        node->right = insertHelper(node->right, key);
    return node;
}

void BST::insert(int key) {
    root = insertHelper(root, key);
}

Node* BST::findMin(Node* node) const {
    while (node && node->left) {
        node = node->left;
    }
    return node;
}

Node* BST::removeHelper(Node* node, int key) {
    if (!node) return nullptr;

    if (key < node->key) {
        node->left = removeHelper(node->left, key);
    } else if (key > node->key) {
        node->right = removeHelper(node->right, key);
    } else {
        // Found the node to delete

        // Case 1: No children (leaf node)
        if (!node->left && !node->right) {
            delete node;
            return nullptr;
        }

        // Case 2: One child
        if (!node->left) {
            Node* temp = node->right;
            delete node;
            return temp;
        }
        if (!node->right) {
            Node* temp = node->left;
            delete node;
            return temp;
        }

        // Case 3: Two children
        // Find the in-order successor (smallest node in right subtree)
        Node* successor = findMin(node->right);
        node->key = successor->key;

        // Now remove the successor node from the right subtree.
        // Instead of recursively calling removeHelper (the correct approach),
        // this code manually walks to the successor and unlinks it.
        Node* parent = node;
        Node* current = node->right;

        if (current == successor) {
            // Successor is the direct right child
            parent->right = successor->right;
        } else {
            // Walk left to find successor's parent
            while (current->left != successor) {
                current = current->left;
            }
            // BUG: Should relink successor's right subtree (successor->right)
            // but instead sets current->left to nullptr, losing the subtree.
            current->left = nullptr;
        }

        delete successor;
    }

    return node;
}

void BST::remove(int key) {
    root = removeHelper(root, key);
}

bool BST::findHelper(Node* node, int key) const {
    if (!node) return false;
    if (key == node->key) return true;
    if (key < node->key) return findHelper(node->left, key);
    return findHelper(node->right, key);
}

bool BST::find(int key) const {
    return findHelper(root, key);
}

void BST::inorderHelper(Node* node, std::vector<int>& result) const {
    if (node) {
        inorderHelper(node->left, result);
        result.push_back(node->key);
        inorderHelper(node->right, result);
    }
}

std::vector<int> BST::inorder() const {
    std::vector<int> result;
    inorderHelper(root, result);
    return result;
}
