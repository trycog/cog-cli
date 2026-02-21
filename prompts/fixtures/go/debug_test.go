package main

import "fmt"

func add(a, b int) int {
	result := a + b       // line 6
	return result          // line 7
}

func multiply(a, b int) int {
	result := a * b       // line 11
	return result          // line 12
}

func compute(x, y int) int {
	sum := add(x, y)              // line 16
	product := multiply(x, y)     // line 17
	final := sum + product        // line 18
	return final                   // line 19
}

func loopSum(n int) int {
	total := 0                     // line 23
	for i := 1; i <= n; i++ {
		total = add(total, i)     // line 25
	}
	return total                   // line 27
}

func factorial(n int) int {
	if n <= 1 {                    // line 31
		return 1                   // line 32
	}
	return n * factorial(n-1)     // line 34
}

func main() {
	x := 10                                // line 38
	y := 20                                // line 39
	result1 := compute(x, y)              // line 40
	fmt.Printf("compute = %d\n", result1) // line 41
	result2 := loopSum(5)                  // line 42
	fmt.Printf("loop_sum = %d\n", result2) // line 43
	result3 := factorial(5)                // line 44
	fmt.Printf("fact = %d\n", result3)    // line 45
}
