import sys
import os
import signal


def divide(a, b):
    return a // b              # line 7 — will crash when b=0


def dereference_none():
    obj = None                 # line 11
    print(obj.value)           # line 12 — AttributeError


def abort_handler():
    os.kill(os.getpid(), signal.SIGABRT)  # line 16 — SIGABRT


def main():
    if len(sys.argv) < 2:                         # line 20
        print(f"Usage: {sys.argv[0]} [divzero|none|abort]")  # line 21
        return 1                                   # line 22
    mode = sys.argv[1]                             # line 23
    print(f"mode: {mode}")                         # line 24
    if mode.startswith("d"):                       # line 25
        divide(10, 0)                              # line 26
    elif mode.startswith("n"):                     # line 27
        dereference_none()                         # line 28
    elif mode.startswith("a"):                     # line 29
        abort_handler()                            # line 30
    return 0                                       # line 31


if __name__ == "__main__":
    sys.exit(main())
