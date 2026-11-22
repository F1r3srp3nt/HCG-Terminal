/*
 * hcg-pty-helper — gives a shell started by HCG Terminal Unleashed a controlling terminal.
 *
 *   hcg-pty-helper [-C <directory>] [--] <program> [arguments…]
 *
 * HCG Terminal starts this helper with posix_spawn() on the secondary side of a pseudo-terminal,
 * in a new session. On Darwin, opening a terminal does not make it the session's controlling
 * terminal, and posix_spawn() has no way to ask for that. Without a controlling terminal the
 * terminal driver cannot deliver Ctrl-C / Ctrl-Z / Ctrl-\ or window-size changes to the
 * foreground program, and shells disable job control.
 *
 * The helper does exactly these things and then replaces itself with the requested program:
 *   1. setsid() if it is not already a session leader;
 *   2. ioctl(0, TIOCSCTTY) to make standard input its controlling terminal;
 *   3. chdir() to the -C directory, if given (iOS has no posix_spawn chdir action);
 *   4. execv() the program with the given arguments and the inherited environment.
 *
 * It does not change user IDs, privileges, signal handlers, the environment or any file, and it
 * never runs anything except the program named by its caller. It is shipped only inside the
 * Unleashed .deb (the sandboxed builds cannot start processes at all).
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    int first = 1;
    const char *directory = NULL;
    if (argc > 2 && strcmp(argv[1], "-C") == 0) { directory = argv[2]; first = 3; }
    if (argc > first && strcmp(argv[first], "--") == 0) first++;
    if (argc <= first) {
        fprintf(stderr, "usage: hcg-pty-helper [-C <directory>] [--] <program> [arguments…]\n");
        return 64;
    }
    if (getsid(0) != getpid()) (void)setsid();
    if (isatty(STDIN_FILENO) && ioctl(STDIN_FILENO, TIOCSCTTY, 0) == -1 && errno != EPERM) {
        /* Not fatal: the program still runs, as it would without the helper. */
        fprintf(stderr, "hcg-pty-helper: no controlling terminal (%s); job control is unavailable.\n", strerror(errno));
    }
    if (directory != NULL && chdir(directory) == -1) {
        /* Like a login shell: start in the inherited directory and say why. */
        fprintf(stderr, "hcg-pty-helper: cannot enter %s: %s\n", directory, strerror(errno));
    }
    execv(argv[first], &argv[first]);
    fprintf(stderr, "hcg-pty-helper: cannot run %s: %s\n", argv[first], strerror(errno));
    return errno == ENOENT ? 127 : 126;
}
