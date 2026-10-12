/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "../Bridge/HBJobPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    assert(hb_ios_valid_dimensions(1920, 1080));
    assert(hb_ios_valid_dimensions(32, 8192));
    assert(!hb_ios_valid_dimensions(30, 1080));
    assert(!hb_ios_valid_dimensions(1919, 1080));
    assert(!hb_ios_valid_dimensions(0, 1080));
    assert(!hb_ios_valid_dimensions(INT_MAX, 1080));
    assert(!hb_ios_valid_dimensions(8194, 1080));
    assert(hb_ios_valid_rate(0));
    assert(hb_ios_valid_rate(23.976));
    assert(!hb_ios_valid_rate(NAN));
    assert(!hb_ios_valid_rate(INFINITY));
    assert(!hb_ios_valid_rate(-1));
    assert(!hb_ios_valid_rate(241));
    const uint64_t reserve = UINT64_C(256) * 1024 * 1024;
    assert(hb_ios_required_space(60, 100, 0, 160, 1) == reserve + 200);
    uint64_t abr = hb_ios_required_space(60, 100, 6000, 160, 2);
    assert(abr >= reserve + UINT64_C(52140000) && abr <= reserve + UINT64_C(52140001));
    assert(hb_ios_required_space(60, UINT64_MAX, 0, 160, 1) == UINT64_MAX);
    assert(hb_ios_required_space(INFINITY, 100, 6000, 160, 1) == UINT64_MAX);
    assert(hb_ios_required_space(60, 100, 6000, 160, -1) == UINT64_MAX);
    assert(hb_ios_required_space(0, 100, 6000, 160, 1) == UINT64_MAX);
    assert(hb_ios_required_space(60, 100, -1, 160, 1) == UINT64_MAX);
    puts("Native job policy: 22 checks passed");
    return 0;
}
