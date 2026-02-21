#ifndef KERNEL_H
#define KERNEL_H

#include <vector>
#include <cstddef>

struct Kernel {
    size_t size;
    std::vector<std::vector<int>> data;

    Kernel(size_t s, std::vector<std::vector<int>> d)
        : size(s), data(std::move(d)) {}

    static Kernel sobelX() {
        return Kernel(3, {
            {-1, 0, 1},
            {-2, 0, 2},
            {-1, 0, 1}
        });
    }

    static Kernel sobelY() {
        return Kernel(3, {
            {-1, -2, -1},
            { 0,  0,  0},
            { 1,  2,  1}
        });
    }
};

#endif
