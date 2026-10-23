/*
 * flootySpawnHelper.c — tiny attach-exec helper spawned by FlootyPTYLayer.
 *
 * Why this exists: on Darwin, fork()ing out of the multithreaded Julia VM
 * produces a child that dies before running anything (libuv kqueue assertion,
 * Objective-C "+initialize after fork" abort). Instead of fork(), the parent
 * posix_spawnp()s THIS program, which runs in a clean single-threaded image:
 *
 *   usage: flootySpawnHelper <slavePath> <-|workdir> <argv...>
 *
 * Steps:
 *   1. setsid()            — detach from Julia's session. When the parent uses
 *                            POSIX_SPAWN_SETSID this is a no-op (already a
 *                            session leader); kept for non-Darwin parents.
 *   2. open(slavePath,O_RDWR) — as a session leader with no controlling tty,
 *                            this BSD-style open ACQUIRES the pty slave as
 *                            controlling terminal.
 *   3. dup2 onto 0/1/2     — full stdio attachment.
 *   4. chdir(workdir)      — skipped when arg is "-"; exit 126 on failure.
 *   5. execvp(argv...)     — replace image; exit 127 if exec fails.
 *
 * Exit codes mirror sh(1): 126 = could not chdir, 127 = could not open tty /
 * bad args / exec failure.
 */
#include <unistd.h>
#include <fcntl.h>

int main(int argc, char **argv)
{
    if (argc < 4)
        return 127;
    const char *slavePath = argv[1];
    const char *dir = argv[2];

    setsid(); /* EPERM if already session leader (Darwin SETSID path) — fine */

    int fd = open(slavePath, O_RDWR);
    if (fd < 0)
        return 127;

    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2)
        close(fd);

    if (!(dir[0] == '-' && dir[1] == '\0')) {
        if (chdir(dir) != 0)
            return 126;
    }

    execvp(argv[3], &argv[3]);
    return 127;
}
