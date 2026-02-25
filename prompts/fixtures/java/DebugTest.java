public class DebugTest {
    static int add(int a, int b) {
        int result = a + b;                           // line 3
        return result;                                // line 4
    }

    static int multiply(int a, int b) {
        int result = a * b;                           // line 8
        return result;                                // line 9
    }

    static int compute(int x, int y) {
        int sum = add(x, y);                          // line 13
        int product = multiply(x, y);                 // line 14
        int fin = sum + product;                      // line 15
        return fin;                                   // line 16
    }

    static int loopSum(int n) {
        int total = 0;                                // line 20
        for (int i = 1; i <= n; i++) {
            total = add(total, i);                    // line 22
        }
        return total;                                 // line 24
    }

    static int factorial(int n) {
        if (n <= 1) return 1;                         // line 28
        return n * factorial(n - 1);                  // line 29
    }

    public static void main(String[] args) {
        int x = 10;                                   // line 33
        int y = 20;                                   // line 34
        int result1 = compute(x, y);                  // line 35
        System.out.printf("compute = %d%n", result1); // line 36
        int result2 = loopSum(5);                     // line 37
        System.out.printf("loop_sum = %d%n", result2);// line 38
        int result3 = factorial(5);                   // line 39
        System.out.printf("fact = %d%n", result3);    // line 40
    }
}
