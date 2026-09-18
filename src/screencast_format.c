#include "screencast_format.h"

#include <limits.h>

#include <wayland-client.h>

bool
screencast_format_get_bytes_per_pixel(uint32_t format,
                                      uint32_t *bytes_per_pixel)
{
    uint32_t value;

    switch (format) {
    case WL_SHM_FORMAT_RGB888:
    case WL_SHM_FORMAT_BGR888:
        value = 3;
        break;
    case WL_SHM_FORMAT_ARGB8888:
    case WL_SHM_FORMAT_XRGB8888:
    case WL_SHM_FORMAT_ABGR8888:
    case WL_SHM_FORMAT_XBGR8888:
        value = 4;
        break;
    default:
        return false;
    }

    if (bytes_per_pixel != NULL)
        *bytes_per_pixel = value;
    return true;
}

bool
screencast_format_calculate_layout(uint32_t format,
                                   uint32_t width,
                                   uint32_t height,
                                   uint32_t *capture_stride,
                                   size_t *capture_size,
                                   uint32_t *pipewire_stride,
                                   size_t *pipewire_size)
{
    uint32_t bytes_per_pixel;

    if (width == 0 || height == 0 ||
        !screencast_format_get_bytes_per_pixel(format, &bytes_per_pixel) ||
        width > UINT32_MAX / bytes_per_pixel || width > UINT32_MAX / 4)
        return false;

    uint32_t source_stride = width * bytes_per_pixel;
    uint32_t target_stride = width * 4;

    if ((size_t) height > SIZE_MAX / source_stride ||
        (size_t) height > SIZE_MAX / target_stride)
        return false;

    size_t source_size = (size_t) source_stride * height;
    size_t target_size = (size_t) target_stride * height;

    /* wl_shm_pool and PipeWire buffer sizes are signed/unsigned 32-bit here. */
    if (source_size > INT32_MAX || target_size > UINT32_MAX)
        return false;

    if (capture_stride != NULL)
        *capture_stride = source_stride;
    if (capture_size != NULL)
        *capture_size = source_size;
    if (pipewire_stride != NULL)
        *pipewire_stride = target_stride;
    if (pipewire_size != NULL)
        *pipewire_size = target_size;
    return true;
}

bool
screencast_format_convert_to_bgrx(uint32_t format,
                                  const uint8_t *source,
                                  uint32_t source_stride,
                                  uint8_t *destination,
                                  uint32_t destination_stride,
                                  uint32_t width,
                                  uint32_t height)
{
    uint32_t source_bytes_per_pixel;

    if (source == NULL || destination == NULL || width == 0 || height == 0 ||
        !screencast_format_get_bytes_per_pixel(
            format, &source_bytes_per_pixel) ||
        width > UINT32_MAX / source_bytes_per_pixel ||
        width > UINT32_MAX / 4 ||
        source_stride < width * source_bytes_per_pixel ||
        destination_stride < width * 4)
        return false;

    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *source_pixel = source + (size_t) y * source_stride;
        uint8_t *destination_pixel =
            destination + (size_t) y * destination_stride;

        for (uint32_t x = 0; x < width; x++) {
            switch (format) {
            case WL_SHM_FORMAT_ARGB8888:
            case WL_SHM_FORMAT_XRGB8888:
                destination_pixel[0] = source_pixel[0];
                destination_pixel[1] = source_pixel[1];
                destination_pixel[2] = source_pixel[2];
                source_pixel += 4;
                break;
            case WL_SHM_FORMAT_ABGR8888:
            case WL_SHM_FORMAT_XBGR8888:
            case WL_SHM_FORMAT_BGR888:
                destination_pixel[0] = source_pixel[2];
                destination_pixel[1] = source_pixel[1];
                destination_pixel[2] = source_pixel[0];
                source_pixel += source_bytes_per_pixel;
                break;
            case WL_SHM_FORMAT_RGB888:
                destination_pixel[0] = source_pixel[0];
                destination_pixel[1] = source_pixel[1];
                destination_pixel[2] = source_pixel[2];
                source_pixel += 3;
                break;
            default:
                return false;
            }
            destination_pixel[3] = 0xff;
            destination_pixel += 4;
        }
    }

    return true;
}
