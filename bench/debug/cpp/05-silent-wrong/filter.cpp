#include "image.h"
#include "kernel.h"
#include <cmath>
#include <algorithm>

Image applyConvolution(const Image& src, const Kernel& kernel) {
    Image result(src.getWidth(), src.getHeight());

    int halfK = static_cast<int>(kernel.size / 2);

    for (size_t y = 0; y < src.getHeight(); y++) {
        for (size_t x = 0; x < src.getWidth(); x++) {
            int sum = 0;

            for (size_t ky = 0; ky < kernel.size; ky++) {
                for (size_t kx = 0; kx < kernel.size; kx++) {
                    // Map kernel coordinates to source image coordinates.
                    // The kernel should be centered on (x, y), so the
                    // correct mapping is:
                    //   sx = x + kx - halfK
                    //   sy = y + ky - halfK
                    //
                    // BUG: Off-by-one in kernel centering. The +1 shifts
                    // the kernel one pixel down and to the right, so each
                    // output pixel is computed from the wrong neighborhood.
                    // The result is a shifted, incorrect edge map.
                    // BUG: Off-by-one in kernel centering. The +1 shifts
                    // the kernel one pixel down and to the right.
                    int sx = static_cast<int>(x) + static_cast<int>(kx) - halfK + 1;
                    int sy = static_cast<int>(y) + static_cast<int>(ky) - halfK + 1;

                    // Clamp to image bounds
                    sx = std::max(0, std::min(sx, static_cast<int>(src.getWidth()) - 1));
                    sy = std::max(0, std::min(sy, static_cast<int>(src.getHeight()) - 1));

                    sum += src.getPixel(static_cast<size_t>(sx),
                                        static_cast<size_t>(sy))
                           * kernel.data[ky][kx];
                }
            }

            result.setPixel(x, y, std::abs(sum));
        }
    }

    return result;
}
