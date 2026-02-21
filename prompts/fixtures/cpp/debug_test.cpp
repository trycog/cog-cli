#include <cstdio>

int add(int a, int b) {
    int result = a + b;        // line 4
    return result;              // line 5
}

int multiply(int a, int b) {
    int result = a * b;        // line 9
    return result;              // line 10
}

int compute(int x, int y) {
    int sum = add(x, y);              // line 14
    int product = multiply(x, y);     // line 15
    int final_ = sum + product;       // line 16
    return final_;                     // line 17
}

int loop_sum(int n) {
    int total = 0;                     // line 21
    for (int i = 1; i <= n; i++) {
        total = add(total, i);        // line 23
    }
    return total;                      // line 25
}

int factorial(int n) {
    if (n <= 1) return 1;             // line 29
    return n * factorial(n - 1);      // line 30
}

int main() {
    int x = 10;                                    // line 34
    int y = 20;                                    // line 35
    int result1 = compute(x, y);                  // line 36
    std::printf("compute = %d\n", result1);       // line 37
    int result2 = loop_sum(5);                     // line 38
    std::printf("loop_sum = %d\n", result2);      // line 39
    int result3 = factorial(5);                    // line 40
    std::printf("fact = %d\n", result3);          // line 41
    return 0;                                      // line 42
}
