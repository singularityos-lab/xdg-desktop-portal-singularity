#include <glib.h>
#include <string.h>
#include <wayland-client.h>

#include "screencast_format.h"

typedef struct {
    uint32_t format;
    uint32_t bytes_per_pixel;
    uint8_t input[4];
    uint8_t expected[4];
} PixelCase;

static void
test_supported_formats_have_exact_layouts(void)
{
    static const PixelCase cases[] = {
        { WL_SHM_FORMAT_ARGB8888, 4, { 0x33, 0x22, 0x11, 0x7f }, { 0x33, 0x22, 0x11, 0xff } },
        { WL_SHM_FORMAT_XRGB8888, 4, { 0x33, 0x22, 0x11, 0x00 }, { 0x33, 0x22, 0x11, 0xff } },
        { WL_SHM_FORMAT_ABGR8888, 4, { 0x11, 0x22, 0x33, 0x7f }, { 0x33, 0x22, 0x11, 0xff } },
        { WL_SHM_FORMAT_XBGR8888, 4, { 0x11, 0x22, 0x33, 0x00 }, { 0x33, 0x22, 0x11, 0xff } },
        { WL_SHM_FORMAT_RGB888,   3, { 0x33, 0x22, 0x11, 0x00 }, { 0x33, 0x22, 0x11, 0xff } },
        { WL_SHM_FORMAT_BGR888,   3, { 0x11, 0x22, 0x33, 0x00 }, { 0x33, 0x22, 0x11, 0xff } },
    };

    for (size_t i = 0; i < G_N_ELEMENTS(cases); i++) {
        uint32_t bytes_per_pixel = 0;
        uint32_t capture_stride = 0;
        uint32_t pipewire_stride = 0;
        size_t capture_size = 0;
        size_t pipewire_size = 0;
        uint8_t output[4] = { 0 };

        g_assert_true(screencast_format_get_bytes_per_pixel(
            cases[i].format, &bytes_per_pixel));
        g_assert_cmpuint(bytes_per_pixel, ==, cases[i].bytes_per_pixel);
        g_assert_true(screencast_format_calculate_layout(
            cases[i].format, 1, 1,
            &capture_stride, &capture_size,
            &pipewire_stride, &pipewire_size));
        g_assert_cmpuint(capture_stride, ==, cases[i].bytes_per_pixel);
        g_assert_cmpuint(capture_size, ==, cases[i].bytes_per_pixel);
        g_assert_cmpuint(pipewire_stride, ==, 4);
        g_assert_cmpuint(pipewire_size, ==, 4);
        g_assert_true(screencast_format_convert_to_bgrx(
            cases[i].format,
            cases[i].input, capture_stride,
            output, pipewire_stride,
            1, 1));
        g_assert_cmpmem(output, sizeof(output),
                        cases[i].expected, sizeof(cases[i].expected));
    }
}

static void
test_conversion_honours_row_padding(void)
{
    const uint8_t input[] = {
        0x11, 0x22, 0x33, 0xaa, 0xbb,
        0x44, 0x55, 0x66, 0xcc, 0xdd,
    };
    uint8_t output[12];
    memset(output, 0xee, sizeof(output));

    g_assert_true(screencast_format_convert_to_bgrx(
        WL_SHM_FORMAT_BGR888, input, 5, output, 6, 1, 2));

    const uint8_t expected[] = {
        0x33, 0x22, 0x11, 0xff, 0xee, 0xee,
        0x66, 0x55, 0x44, 0xff, 0xee, 0xee,
    };
    g_assert_cmpmem(output, sizeof(output), expected, sizeof(expected));
}

static void
test_invalid_and_overflowing_layouts_are_rejected(void)
{
    uint32_t capture_stride;
    uint32_t pipewire_stride;
    size_t capture_size;
    size_t pipewire_size;

    g_assert_false(screencast_format_calculate_layout(
        0xdeadbeefu, 1920, 1080, &capture_stride, &capture_size,
        &pipewire_stride, &pipewire_size));
    g_assert_false(screencast_format_calculate_layout(
        WL_SHM_FORMAT_XRGB8888, UINT32_MAX, UINT32_MAX,
        &capture_stride, &capture_size,
        &pipewire_stride, &pipewire_size));
}

int
main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/screencast/format/supported-layouts",
                    test_supported_formats_have_exact_layouts);
    g_test_add_func("/screencast/format/row-padding",
                    test_conversion_honours_row_padding);
    g_test_add_func("/screencast/format/invalid-layouts",
                    test_invalid_and_overflowing_layouts_are_rejected);
    return g_test_run();
}
