# SPDX-License-Identifier: GPL-2.0-or-later
"""Exercise the real VT callback/error policy without requiring an Apple SDK.

The production function bodies are compiled with minimal CoreMedia stubs. This
checks failure propagation and ownership, not VideoToolbox availability or device
encoding; those remain responsibilities of the iOS integration tests.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


def function_body(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class VideoToolboxErrorTests(unittest.TestCase):
    def test_callback_ownership_and_job_failure(self):
        compiler = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
        if compiler is None:
            self.skipTest("A C compiler is required for the isolated VT policy test")
        source = (Path(__file__).parents[1] / "platform/macosx/encvt.c").read_text()
        callback = function_body(source, "void hb_vt_compression_output_callback(")
        policy = function_body(source, "static int hb_vt_check_output_error(")
        fixture = r"""
#include <assert.h>
#include <stdlib.h>
#define TARGET_OS_OSX 0
#define __ATOMIC_RELAXED 0
#define noErr 0
#define kVTVideoEncoderMalfunctionErr -12912
#define HB_ERROR_UNKNOWN 4
typedef int OSStatus;
typedef unsigned VTEncodeInfoFlags;
typedef struct { int retains; } sample_t;
typedef sample_t *CMSampleBufferRef;
typedef struct { int enqueue_error; } queue_t;
typedef queue_t *CMSimpleQueueRef;
typedef struct { CMSimpleQueueRef queue; int error; } hb_vt_output_context_t;
typedef struct { int released; } hb_buffer_t;
typedef struct { int *die; int *done_error; } job_t;
typedef struct { hb_vt_output_context_t *output_context; job_t *job; } hb_work_private_t;
static void hb_log(const char *s) { (void)s; }
static void hb_error(const char *s, int err) { (void)s; (void)err; }
static void hb_vt_add_dynamic_hdr_metadata(CMSampleBufferRef s, hb_buffer_t *b) { (void)s; (void)b; }
static void hb_buffer_close(hb_buffer_t **b) { (*b)->released++; *b = NULL; }
static void CFRetain(CMSampleBufferRef s) { s->retains++; }
static void CFRelease(CMSampleBufferRef s) { s->retains--; }
static int CMSimpleQueueEnqueue(CMSimpleQueueRef q, CMSampleBufferRef s) { (void)s; return q->enqueue_error; }
"""
        cases = r"""
int main(void) {
    queue_t queue = {0};
    hb_vt_output_context_t context = { &queue, 0 };
    int die = 0, error = 0;
    job_t job = { &die, &error };
    hb_work_private_t first_pass = { &context, &job };
    hb_work_private_t final_pass = { &context, &job };
    hb_buffer_t input = {0};
    sample_t sample = {0};

    hb_vt_compression_output_callback(&context, &input, 0, 0, &sample);
    assert(input.released == 1 && sample.retains == 1);
    assert(!hb_vt_check_output_error(&first_pass) && !die && !error);
    CFRelease(&sample); /* queue consumer releases its ownership */

    queue.enqueue_error = -7;
    hb_vt_compression_output_callback(&context, &input, 0, 0, &sample);
    assert(input.released == 2 && sample.retains == 0);
    assert(context.error == -7);
    assert(hb_vt_check_output_error(&final_pass) && die && error == HB_ERROR_UNKNOWN);

    context.error = die = error = 0;
    hb_vt_compression_output_callback(&context, &input, -42, 0, NULL);
    assert(input.released == 3 && context.error == -42);
    assert(hb_vt_check_output_error(&final_pass) && die && error == HB_ERROR_UNKNOWN);

    context.error = die = error = 0;
    hb_vt_compression_output_callback(&context, &input, 0, 0, NULL);
    assert(input.released == 4 && context.error == kVTVideoEncoderMalfunctionErr);
    assert(hb_vt_check_output_error(&final_pass) && die && error == HB_ERROR_UNKNOWN);
    return 0;
}
"""
        with tempfile.TemporaryDirectory(prefix="hb-vt-policy-") as directory:
            path = Path(directory)
            (path / "test.c").write_text(fixture + callback + "\n" + policy + "\n" + cases)
            subprocess.run([compiler, "-std=gnu99", "-Wall", "-Wextra", str(path / "test.c"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
