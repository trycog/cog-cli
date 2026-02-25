public class DebugSleep {
    static int counter = 0;                           // line 2

    static void tick() {
        counter++;                                    // line 5
        System.out.printf("tick %d%n", counter);      // line 6
    }

    public static void main(String[] args) throws InterruptedException {
        System.out.printf("pid: %d%n", ProcessHandle.current().pid()); // line 10
        System.out.flush();                           // line 11
        for (int i = 0; i < 300; i++) {               // line 12
            tick();                                   // line 13
            Thread.sleep(1000);                       // line 14
        }
    }
}
