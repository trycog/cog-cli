#ifndef IMAGE_H
#define IMAGE_H

#include <vector>
#include <cstddef>

class Image {
public:
    Image(size_t width, size_t height);
    Image(size_t width, size_t height, const std::vector<int>& data);

    int getPixel(size_t x, size_t y) const;
    void setPixel(size_t x, size_t y, int value);

    size_t getWidth() const { return width_; }
    size_t getHeight() const { return height_; }

    unsigned int checksum() const;

private:
    size_t width_;
    size_t height_;
    std::vector<int> pixels_;
};

#endif
