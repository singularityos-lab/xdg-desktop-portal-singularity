#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool screencast_format_get_bytes_per_pixel(uint32_t format,
                                           uint32_t *bytes_per_pixel);

bool screencast_format_calculate_layout(uint32_t format,
                                        uint32_t width,
                                        uint32_t height,
                                        uint32_t *capture_stride,
                                        size_t *capture_size,
                                        uint32_t *pipewire_stride,
                                        size_t *pipewire_size);

bool screencast_format_convert_to_bgrx(uint32_t format,
                                       const uint8_t *source,
                                       uint32_t source_stride,
                                       uint8_t *destination,
                                       uint32_t destination_stride,
                                       uint32_t width,
                                       uint32_t height);
