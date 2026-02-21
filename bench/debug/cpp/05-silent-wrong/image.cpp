#include "image.h"

Image::Image(size_t w, size_t h)
    : width_(w), height_(h), pixels_(w * h, 0) {}

Image::Image(size_t w, size_t h, const std::vector<int>& data)
    : width_(w), height_(h), pixels_(data) {}

int Image::getPixel(size_t x, size_t y) const {
    if (x >= width_ || y >= height_) return 0;
    return pixels_[y * width_ + x];
}

void Image::setPixel(size_t x, size_t y, int value) {
    if (x < width_ && y < height_) {
        pixels_[y * width_ + x] = value;
    }
}

unsigned int Image::checksum() const {
    unsigned int hash = 0;
    for (int p : pixels_) {
        hash = hash * 31 + static_cast<unsigned int>(p & 0xFF);
    }
    return hash & 0xFFFF;
}
