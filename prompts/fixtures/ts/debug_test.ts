"use strict";

function add(a: number, b: number): number {
    const result: number = a + b;      // line 4
    return result;                      // line 5
}

function multiply(a: number, b: number): number {
    const result: number = a * b;      // line 9
    return result;                      // line 10
}

function compute(x: number, y: number): number {
    const sum: number = add(x, y);             // line 14
    const product: number = multiply(x, y);    // line 15
    const final_: number = sum + product;      // line 16
    return final_;                              // line 17
}

function loopSum(n: number): number {
    let total: number = 0;                      // line 21
    for (let i: number = 1; i <= n; i++) {
        total = add(total, i);                 // line 23
    }
    return total;                               // line 25
}

function factorial(n: number): number {
    if (n <= 1) return 1;                      // line 29
    return n * factorial(n - 1);               // line 30
}

function main(): void {
    const x: number = 10;                               // line 34
    const y: number = 20;                               // line 35
    const result1: number = compute(x, y);              // line 36
    console.log(`compute = ${result1}`);                // line 37
    const result2: number = loopSum(5);                 // line 38
    console.log(`loop_sum = ${result2}`);               // line 39
    const result3: number = factorial(5);               // line 40
    console.log(`fact = ${result3}`);                   // line 41
}

main();
