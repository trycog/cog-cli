#include <cstdio>
#include <cstring>

int global_count = 100;                // line 4

struct Point {                          // line 6
    int x;                              // line 7
    int y;                              // line 8
    char name[32];                      // line 9
};

void modify(int *val, int delta) {
    *val += delta;                      // line 13
}

int process(int a, int b, int c) {
    int local1 = a + b;                // line 17
    int local2 = b + c;                // line 18
    int local3 = local1 * local2;      // line 19
    return local3;                      // line 20
}

int main() {
    int x = 5;                          // line 24
    int y = 10;                         // line 25
    int z = 15;                         // line 26
    Point pt;                           // line 27
    pt.x = 100;                         // line 28
    pt.y = 200;                         // line 29
    std::strcpy(pt.name, "origin");    // line 30
    modify(&x, 3);                      // line 31
    int result = process(x, y, z);     // line 32
    std::printf("x=%d result=%d global=%d\n", x, result, global_count); // line 33
    std::printf("pt=(%d,%d,%s)\n", pt.x, pt.y, pt.name);               // line 34
    return 0;                           // line 35
}
