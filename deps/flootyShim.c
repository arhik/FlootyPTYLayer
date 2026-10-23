/*
 * flootyShim.c — non-variadic wrappers around Darwin's variadic ioctl.
 *
 * Why: on Apple Silicon, C variadic arguments must be passed on the stack,
 * but Julia's ccall places them in registers. Any ioctl whose command
 * dereferences the third argument therefore reads garbage (silently writing
 * elsewhere => rc=0 with our buffers untouched). Wrapping each ioctl use in
 * a plain (non-variadic) C function sidesteps the ABI mismatch entirely.
 *
 * Built by buildFlootyShim!() into deps/ on first load.
 */
#include <sys/ioctl.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#include <unistd.h>
#endif

/* TIOCSWINSZ: set window size on a tty fd. Returns ioctl rc (-1 on error). */
int flootySetWinsize(int fd, int rows, int cols) {
    struct winsize ws;
    ws.ws_row = (unsigned short)(rows & 0xffff);
    ws.ws_col = (unsigned short)(cols & 0xffff);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

/* TIOCGWINSZ: read window size into caller ints. Returns ioctl rc. */
int flootyGetWinsize(int fd, int *rows, int *cols) {
    struct winsize ws;
    int rc = ioctl(fd, TIOCGWINSZ, &ws);
    if (rc == 0) {
        *rows = (int)ws.ws_row;
        *cols = (int)ws.ws_col;
    }
    return rc;
}

/* TIOCSCTTY: make the given tty fd the controlling terminal of the caller.
 * Must be invoked AFTER setsid() from the child branch. */
int flootyAcquireCtty(int slaveFd) {
#if defined(TIOCSCTTY)
    return ioctl(slaveFd, TIOCSCTTY, (void *)0);
#else
    (void)slaveFd;
    return 0; /* platforms without TIOCSCTTY rely on login_tty semantics */
#endif
}

/* ptsname(3) performs an ioctl internally (TIOCPTYGNAME), so calling it via
 * ccall hits the same variadic-ABI bug; wrap it here instead. Returns 0 and
 * fills buf with e.g. "/dev/ttys007", or -1 on failure. */
int flootySlaveName(int masterFd, char *buf, int bufLen) {
    if (buf == NULL || bufLen <= 0) return -1;
    const char *p = ptsname(masterFd);
    if (p == NULL) return -1;
    size_t n = strlen(p);
    if ((int)n >= bufLen) return -1;
    memcpy(buf, p, n + 1);
    return 0;
}
