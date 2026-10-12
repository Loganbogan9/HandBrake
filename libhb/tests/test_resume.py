# SPDX-License-Identifier: GPL-2.0-or-later
"""Compile the real resume function and check pass lifetime with AddressSanitizer."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_vt_error import function_body


class ResumeTests(unittest.TestCase):
    def test_prescan_completion_and_concurrent_pass_lifetime(self):
        compiler = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
        if compiler is None:
            self.skipTest("A C compiler with AddressSanitizer is required")
        source = (Path(__file__).parents[1] / "hb.c").read_text()
        resume = function_body(source, "void hb_resume( hb_handle_t * h )")
        fixture = r"""
#include <assert.h>
#include <stdint.h>
#include <pthread.h>
#include <stdlib.h>
typedef pthread_mutex_t hb_lock_t;
typedef struct { int64_t st_paused; } hb_job_t;
typedef struct {
    int paused;
    int64_t pause_date, pause_duration;
    hb_lock_t *pause_lock, *state_lock;
    hb_job_t *current_job;
    struct { struct { struct { int64_t paused; } working; } param; } state;
} hb_handle_t;
static int64_t hb_get_date(void) { return 400; }
static void hb_lock(hb_lock_t *m) { assert(!pthread_mutex_lock(m)); }
static void hb_unlock(hb_lock_t *m) { assert(!pthread_mutex_unlock(m)); }
"""
        cases = r"""
static void *worker(void *argument) {
    hb_handle_t *h = argument;
    for (int i = 0; i < 25000; i++) {
        hb_job_t *job = calloc(1, sizeof(*job));
        assert(job);
        hb_lock(h->state_lock);
        h->current_job = job;
        hb_unlock(h->state_lock);
        hb_lock(h->state_lock);
        h->current_job = NULL;
        hb_unlock(h->state_lock);
        free(job);
    }
    return NULL;
}
int main(void) {
    hb_lock_t pause_lock = PTHREAD_MUTEX_INITIALIZER;
    hb_lock_t state_lock = PTHREAD_MUTEX_INITIALIZER;
    hb_handle_t h = { .paused = 1, .pause_date = 100,
                      .pause_lock = &pause_lock, .state_lock = &state_lock };
    hb_lock(&pause_lock);
    hb_resume(&h); /* JSON pre-scan or finished pass: current_job == NULL */
    assert(!h.paused && h.pause_date == -1 && h.pause_duration == 300);
    assert(h.state.param.working.paused == 300);
    assert(!pthread_mutex_trylock(&pause_lock));
    hb_unlock(&pause_lock);

    hb_job_t job = { .st_paused = 7 };
    h.current_job = &job; h.paused = 1; h.pause_date = 100;
    hb_lock(&pause_lock);
    hb_resume(&h);
    assert(job.st_paused == 307 && h.pause_duration == 600 && !h.paused);
    hb_resume(&h); /* an unpaused handle is unchanged */
    assert(job.st_paused == 307 && h.pause_duration == 600);

    h.current_job = NULL;
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, worker, &h));
    for (int i = 0; i < 25000; i++) {
        hb_lock(&pause_lock);
        h.paused = 1; h.pause_date = 100;
        hb_resume(&h);
        assert(!h.paused);
    }
    assert(!pthread_join(thread, NULL));
    pthread_mutex_destroy(&pause_lock);
    pthread_mutex_destroy(&state_lock);
    return 0;
}
"""
        with tempfile.TemporaryDirectory(prefix="hb-resume-") as directory:
            path = Path(directory)
            (path / "test.c").write_text(fixture + resume + "\n" + cases)
            subprocess.run([compiler, "-std=gnu99", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address", "-pthread", str(path / "test.c"),
                            "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
