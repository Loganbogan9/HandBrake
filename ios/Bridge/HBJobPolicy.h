/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HB_IOS_JOB_POLICY_H
#define HB_IOS_JOB_POLICY_H
#include <math.h>
#include <stdint.h>
#include <limits.h>

/* UI dimensions are bounding limits, not forced dimensions. libhb preserves DAR.
 * Bound resource requests before they reach native allocation/encoder code. */
static inline int hb_ios_valid_dimensions(int width, int height)
{
    return width >= 32 && height >= 32 && width <= 8192 && height <= 8192 &&
           !(width & 1) && !(height & 1);
}
static inline int hb_ios_valid_rate(double fps)
{
    return isfinite(fps) && (fps == 0 || (fps >= 1 && fps <= 240));
}
static inline uint64_t hb_ios_required_space(double seconds, uint64_t source_bytes,
                                            int video_kbps, int audio_kbps, int audio_tracks)
{
    const uint64_t reserve = UINT64_C(256) * 1024 * 1024;
    if (!isfinite(seconds) || seconds <= 0 || audio_tracks < 0 || audio_kbps < 0 ||
        video_kbps < 0) return UINT64_MAX;
    long double payload;
    if (video_kbps == 0) /* CQ output cannot be predicted; reserve twice the input. */
        payload = (long double)source_bytes * 2;
    else
        payload = (long double)seconds *
            ((long double)video_kbps + (long double)audio_kbps * audio_tracks) * 125 * 1.10L;
    if (payload >= (long double)UINT64_MAX - reserve) return UINT64_MAX;
    return (uint64_t)ceill(payload) + reserve;
}
#endif
