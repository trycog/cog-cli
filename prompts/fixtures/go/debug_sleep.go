package main

import (
	"fmt"
	"os"
	"time"
)

var counter = 0                    // line 9

func tick() {
	counter++                      // line 12
	fmt.Printf("tick %d\n", counter) // line 13
}

func main() {
	fmt.Printf("pid: %d\n", os.Getpid()) // line 17
	for i := 0; i < 300; i++ {            // line 18
		tick()                             // line 19
		time.Sleep(time.Second)           // line 20
	}
}
