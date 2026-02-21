import os
import sys
import time


counter = 0                        # line 6


def tick():
    global counter
    counter += 1                   # line 11
    print(f"tick {counter}")       # line 12


def main():
    print(f"pid: {os.getpid()}")   # line 16
    sys.stdout.flush()             # line 17
    for i in range(300):           # line 18
        tick()                     # line 19
        time.sleep(1)             # line 20
    return 0                       # line 21


if __name__ == "__main__":
    sys.exit(main())
