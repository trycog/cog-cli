public class DebugVars {
    static int globalCount = 100;                     // line 2

    static class Point {                              // line 4
        int x;                                        // line 5
        int y;                                        // line 6
        String name;                                  // line 7
        Point(int x, int y, String name) {            // line 8
            this.x = x;                               // line 9
            this.y = y;                               // line 10
            this.name = name;                         // line 11
        }
    }

    static int modify(int val, int delta) {
        return val + delta;                           // line 16
    }

    static int process(int a, int b, int c) {
        int local1 = a + b;                           // line 20
        int local2 = b + c;                           // line 21
        int local3 = local1 * local2;                 // line 22
        return local3;                                // line 23
    }

    public static void main(String[] args) {
        int x = 5;                                    // line 27
        int y = 10;                                   // line 28
        int z = 15;                                   // line 29
        Point pt = new Point(100, 200, "origin");     // line 30
        x = modify(x, 3);                             // line 31
        int result = process(x, y, z);                // line 32
        System.out.printf("x=%d result=%d global=%d%n", x, result, globalCount); // line 33
        System.out.printf("pt=(%d,%d,%s)%n", pt.x, pt.y, pt.name);              // line 34
    }
}
