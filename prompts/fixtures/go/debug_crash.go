package main

import (
	"fmt"
	"os"
	"unsafe"
)

func divide(a, b int) int {
	return a / b               // line 10 — will panic when b=0
}

func dereferenceNil() {
	var p *int                 // line 14
	fmt.Println(*p)            // line 15 — nil pointer dereference
}

func abortHandler() {
	panic("abort requested")  // line 19 — panic
}

func main() {
	if len(os.Args) < 2 {                              // line 23
		fmt.Printf("Usage: %s [divzero|nil|abort]\n", os.Args[0]) // line 24
		os.Exit(1)                                      // line 25
	}
	mode := os.Args[1]                                 // line 27
	fmt.Printf("mode: %s\n", mode)                    // line 28
	_ = unsafe.Pointer(nil)
	if mode[0] == 'd' {                               // line 30
		divide(10, 0)                                  // line 31
	} else if mode[0] == 'n' {                         // line 32
		dereferenceNil()                               // line 33
	} else if mode[0] == 'a' {                         // line 34
		abortHandler()                                 // line 35
	}
}
