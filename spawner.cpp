#include <cerrno>
#include <climits>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iostream>
#include <string>
#include <vector>

#include <sys/wait.h>
#include <unistd.h>

namespace {

constexpr int kMaxChildren = 10000;

struct Args {
    int num = -1;
    int duration = -1;
    bool quiet = false;
};

volatile sig_atomic_t g_stop = 0;
pid_t g_pgid = 0;

void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

void print_usage(const char* prog) {
    std::fprintf(stderr,
        "Usage: %s --num N --duration S [--quiet]\n"
        "  --num N         number of child processes to fork (1..%d)\n"
        "  --duration S    seconds each child sleeps before exiting (>=1)\n"
        "  --quiet         suppress per-step logs\n"
        "Example: %s --num 100 --duration 300\n",
        prog, kMaxChildren, prog);
}

bool parse_int(const char* s, int& out) {
    if (!s || !*s) return false;
    char* end = nullptr;
    errno = 0;
    long v = std::strtol(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0') return false;
    if (v < INT_MIN || v > INT_MAX) return false;
    out = static_cast<int>(v);
    return true;
}

bool parse_args(int argc, char** argv, Args& args) {
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--num" && i + 1 < argc) {
            if (!parse_int(argv[++i], args.num)) return false;
        } else if (a == "--duration" && i + 1 < argc) {
            if (!parse_int(argv[++i], args.duration)) return false;
        } else if (a == "--quiet") {
            args.quiet = true;
        } else if (a == "-h" || a == "--help") {
            return false;
        } else {
            std::fprintf(stderr, "unknown arg: %s\n", a.c_str());
            return false;
        }
    }
    if (args.num < 1 || args.num > kMaxChildren) {
        std::fprintf(stderr, "--num must be in [1, %d]\n", kMaxChildren);
        return false;
    }
    if (args.duration < 1) {
        std::fprintf(stderr, "--duration must be >= 1\n");
        return false;
    }
    return true;
}

void log_ts(const char* tag, const std::string& msg, bool quiet) {
    if (quiet) return;
    std::time_t t = std::time(nullptr);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%H:%M:%S", std::localtime(&t));
    std::fprintf(stdout, "[%s %s] %s\n", buf, tag, msg.c_str());
    std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
    Args args;
    if (!parse_args(argc, argv, args)) {
        print_usage(argv[0]);
        return 1;
    }

    if (setpgid(0, 0) != 0) {
        std::fprintf(stderr, "warning: setpgid failed: %s\n", std::strerror(errno));
    }
    g_pgid = getpgrp();

    struct sigaction sa{};
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);

    pid_t ppid = getpid();
    {
        char msg[128];
        std::snprintf(msg, sizeof(msg),
            "parent pid=%d pgid=%d, spawning %d children for %ds",
            ppid, g_pgid, args.num, args.duration);
        log_ts("parent", msg, args.quiet);
    }

    std::vector<pid_t> children;
    children.reserve(args.num);

    int spawn_failed = 0;
    for (int i = 0; i < args.num; ++i) {
        if (g_stop) break;
        pid_t pid = fork();
        if (pid == 0) {
            std::signal(SIGINT, SIG_DFL);
            std::signal(SIGTERM, SIG_DFL);
            unsigned int remaining = static_cast<unsigned int>(args.duration);
            while (remaining > 0) remaining = sleep(remaining);
            _exit(0);
        } else if (pid > 0) {
            children.push_back(pid);
        } else {
            spawn_failed = args.num - i;
            std::fprintf(stderr,
                "fork failed at i=%d (%s); spawned %d of %d\n",
                i, std::strerror(errno), i, args.num);
            break;
        }
    }

    {
        char msg[128];
        std::snprintf(msg, sizeof(msg),
            "spawned %zu children%s",
            children.size(),
            spawn_failed ? " (partial)" : "");
        log_ts("parent", msg, args.quiet);
    }

    if (g_stop) {
        log_ts("parent", "signal received before spawn complete, terminating group", args.quiet);
        killpg(g_pgid, SIGTERM);
    }

    int ok = 0, bad = 0;
    bool termed = false;
    for (pid_t pid : children) {
        int status = 0;
        while (true) {
            pid_t r = waitpid(pid, &status, 0);
            if (r == -1) {
                if (errno == EINTR) {
                    if (g_stop && !termed) {
                        log_ts("parent", "signal received, sending SIGTERM to group", args.quiet);
                        killpg(g_pgid, SIGTERM);
                        termed = true;
                    }
                    continue;
                }
                std::fprintf(stderr, "waitpid(%d) failed: %s\n", pid, std::strerror(errno));
                ++bad;
                break;
            }
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) ++ok;
            else ++bad;
            break;
        }
    }

    {
        char msg[160];
        std::snprintf(msg, sizeof(msg),
            "done: %d exited clean, %d abnormal, %d fork-failed",
            ok, bad, spawn_failed);
        log_ts("parent", msg, args.quiet);
    }

    return (bad == 0 && spawn_failed == 0) ? 0 : 2;
}
