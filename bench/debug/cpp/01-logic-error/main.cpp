#include "bst.h"
#include <iostream>

int main() {
    BST tree;

    // Build a BST:
    //          10
    //         /  \
    //        5    15
    //       / \   / \
    //      2   8 12  20
    //             \
    //             13
    tree.insert(10);
    tree.insert(5);
    tree.insert(15);
    tree.insert(2);
    tree.insert(8);
    tree.insert(12);
    tree.insert(20);
    tree.insert(13);  // Right child of 12 -- will be lost due to bug

    // Delete root node 10 (two children case).
    // In-order successor is 12 (leftmost of right subtree).
    // 12 has a right child (13) that must be relinked.
    // Bug: successor's right child (13) is not relinked, so it is lost.
    tree.remove(10);

    // Print in-order traversal
    auto result = tree.inorder();
    std::cout << "Traversal:";
    for (int val : result) {
        std::cout << " " << val;
    }
    std::cout << std::endl;

    return 0;
}
