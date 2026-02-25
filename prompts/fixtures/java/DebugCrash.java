public class DebugCrash {
    static int divide(int a, int b) {
        return a / b;                                 // line 3 — ArithmeticException when b=0
    }

    static void dereferenceNull() {
        String s = null;                              // line 7
        System.out.println(s.length());               // line 8 — NullPointerException
    }

    static void abortHandler() {
        throw new RuntimeException("abort requested");// line 12
    }

    public static void main(String[] args) {
        if (args.length < 1) {                        // line 16
            System.out.printf("Usage: DebugCrash [divzero|null|abort]%n"); // line 17
            System.exit(1);                           // line 18
        }
        System.out.printf("mode: %s%n", args[0]);    // line 20
        if (args[0].startsWith("d")) {                // line 21
            divide(10, 0);                            // line 22
        } else if (args[0].startsWith("n")) {         // line 23
            dereferenceNull();                        // line 24
        } else if (args[0].startsWith("a")) {         // line 25
            abortHandler();                           // line 26
        }
    }
}
