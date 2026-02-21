#include "image.h"
#include "kernel.h"
#include <iostream>
#include <iomanip>
#include <cmath>
#include <algorithm>

// Declared in filter.cpp
Image applyConvolution(const Image& src, const Kernel& kernel);

int main() {
    // Create a 5x5 test image with a sharp vertical edge:
    //   Left half is dark (20), right half is bright (220).
    //   Row 0: 20 20 20 220 220
    //   Row 1: 20 20 20 220 220
    //   Row 2: 20 20 20 220 220
    //   Row 3: 20 20 20 220 220
    //   Row 4: 20 20 20 220 220
    //
    // Sobel X should detect a strong vertical edge at columns 2 and 3.
    // Sobel Y should detect no horizontal edges (uniform rows).
    const size_t W = 5, H = 5;
    Image img(W, H);

    for (size_t y = 0; y < H; y++) {
        for (size_t x = 0; x < W; x++) {
            img.setPixel(x, y, (x < 3) ? 20 : 220);
        }
    }

    // Apply Sobel edge detection
    Image sobelX = applyConvolution(img, Kernel::sobelX());
    Image sobelY = applyConvolution(img, Kernel::sobelY());

    // Combine: magnitude = sqrt(gx^2 + gy^2), clamped to 255
    Image edges(W, H);
    for (size_t y = 0; y < H; y++) {
        for (size_t x = 0; x < W; x++) {
            int gx = sobelX.getPixel(x, y);
            int gy = sobelY.getPixel(x, y);
            int magnitude = static_cast<int>(
                std::sqrt(static_cast<double>(gx * gx + gy * gy)));
            edges.setPixel(x, y, std::min(255, magnitude));
        }
    }

    // Print the full edge detection result.
    // With correct kernel centering, the strong edges appear at columns 2-3.
    // With the off-by-one bug, the edges shift one pixel to the left (columns 1-2).
    std::cout << "Edge detection:" << std::endl;
    for (size_t y = 0; y < H; y++) {
        for (size_t x = 0; x < W; x++) {
            if (x > 0) std::cout << " ";
            std::cout << std::setw(3) << edges.getPixel(x, y);
        }
        std::cout << std::endl;
    }

    return 0;
}
