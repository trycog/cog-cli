"use strict";

function add(a, b) {
    const result = a + b;      // line 4
    return result;              // line 5
}

function multiply(a, b) {
    const result = a * b;      // line 9
    return result;              // line 10
}

function compute(x, y) {
    const sum = add(x, y);             // line 14
    const product = multiply(x, y);    // line 15
    const final_ = sum + product;      // line 16
    return final_;                      // line 17
}

function loopSum(n) {
    let total = 0;                      // line 21
    for (let i = 1; i <= n; i++) {
        total = add(total, i);         // line 23
    }
    return total;                       // line 25
}

function factorial(n) {
    if (n <= 1) return 1;              // line 29
    return n * factorial(n - 1);       // line 30
}

function main() {
    const x = 10;                               // line 34
    const y = 20;                               // line 35
    const result1 = compute(x, y);             // line 36
    console.log(`compute = ${result1}`);        // line 37
    const result2 = loopSum(5);                 // line 38
    console.log(`loop_sum = ${result2}`);       // line 39
    const result3 = factorial(5);               // line 40
    console.log(`fact = ${result3}`);           // line 41
}

main();
