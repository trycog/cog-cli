#include <cstdio>
#include <cstdlib>
#include <cstring>

int divide(int a, int b) {
    return a / b;              // line 6 — will crash when b=0
}

void dereference_null() {
    int *p = nullptr;          // line 10
    std::printf("%d\n", *p);   // line 11 — SIGSEGV
}

void abort_handler() {
    std::abort();              // line 15 — SIGABRT
}

int main(int argc, char *argv[]) {
    if (argc < 2) {                                        // line 19
        std::printf("Usage: %s [divzero|null|abort]\n", argv[0]);  // line 20
        return 1;                                          // line 21
    }
    std::printf("mode: %s\n", argv[1]);                   // line 23
    if (argv[1][0] == 'd') {                              // line 24
        divide(10, 0);                                     // line 25
    } else if (argv[1][0] == 'n') {                       // line 26
        dereference_null();                                // line 27
    } else if (argv[1][0] == 'a') {                       // line 28
        abort_handler();                                   // line 29
    }
    return 0;                                              // line 31
}
