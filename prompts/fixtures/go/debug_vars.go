package main

import "fmt"

var globalCount = 100                  // line 5

type Point struct {                    // line 7
	X    int                           // line 8
	Y    int                           // line 9
	Name string                        // line 10
}

func modify(val *int, delta int) {
	*val += delta                      // line 14
}

func process(a, b, c int) int {
	local1 := a + b                    // line 18
	local2 := b + c                    // line 19
	local3 := local1 * local2          // line 20
	return local3                      // line 21
}

func main() {
	x := 5                             // line 25
	y := 10                            // line 26
	z := 15                            // line 27
	pt := Point{X: 100, Y: 200, Name: "origin"} // line 28
	modify(&x, 3)                      // line 29
	result := process(x, y, z)         // line 30
	fmt.Printf("x=%d result=%d global=%d\n", x, result, globalCount)  // line 31
	fmt.Printf("pt=(%d,%d,%s)\n", pt.X, pt.Y, pt.Name)               // line 32
}
