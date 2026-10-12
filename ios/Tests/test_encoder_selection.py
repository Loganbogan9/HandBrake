# SPDX-License-Identifier: GPL-2.0-or-later
"""Compile the production bridge lookup against a small runtime encoder list.

This is a name/availability policy test, not an iOS engine substitute. Native
integration tests still run the real libhb pipeline under Xcode.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class EncoderSelectionTests(unittest.TestCase):
    def test_known_disabled_names_cannot_resolve_to_an_enabled_fallback(self):
        compiler = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
        if not compiler:
            self.skipTest("A C compiler is needed for the production lookup policy test")
        source = (Path(__file__).resolve().parents[1] / "Bridge/HBEngine.mm").read_text()
        start = source.index("static const hb_encoder_t *findEncoder(")
        end = source.index("\nstatic NSDictionary *canonicalPreset", start)
        policy = source[start:end]
        fixture = r'''
#include <assert.h>
#include <stddef.h>
#include <string.h>
typedef struct { const char *short_name; int codec; } hb_encoder_t;
static const hb_encoder_t video[] = {{"x264", 1}, {"vt_h265", 2}};
static const hb_encoder_t audio[] = {{"ca_aac", 3}, {"av_aac", 4}};
static const hb_encoder_t *hb_video_encoder_get_next(const hb_encoder_t *last) {
    if (!last) return video;
    return last == video ? video + 1 : NULL;
}
static const hb_encoder_t *hb_audio_encoder_get_next(const hb_encoder_t *last) {
    if (!last) return audio;
    return last == audio ? audio + 1 : NULL;
}
'''
        cases = r'''
int main(void) {
    assert(findEncoder("x264", 1)->codec == 1);
    assert(findEncoder("vt_h265", 1)->codec == 2);
    assert(findEncoder("ca_aac", 0)->codec == 3);
    assert(findEncoder("av_aac", 0)->codec == 4);
    /* libhb's legacy name APIs may map these to a different enabled codec.
       An explicit mobile request must instead fail before creating a job. */
    assert(findEncoder("fdk_aac", 0) == NULL);
    assert(findEncoder("vt_h265_10bit", 1) == NULL);
    assert(findEncoder("x264_10bit", 1) == NULL);
    assert(findEncoder("unavailable_test_encoder", 1) == NULL);
    assert(findEncoder("aac", 0) == NULL);
    assert(findEncoder(NULL, 0) == NULL);
    assert(findEncoder("ca_aac", 1) == NULL);
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="hb-encoder-policy-") as directory:
            directory = Path(directory)
            (directory / "test.c").write_text(fixture + policy + cases)
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            str(directory / "test.c"), "-o", str(directory / "test")], check=True)
            subprocess.run([str(directory / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
