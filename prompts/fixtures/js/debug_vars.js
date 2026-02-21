"use strict";

let globalCount = 100;                 // line 3

class Point {                          // line 5
    constructor(x, y, name) {
        this.x = x;                    // line 7
        this.y = y;                    // line 8
        this.name = name;              // line 9
    }
}

function modify(val, delta) {
    return val + delta;                // line 14
}

function process(a, b, c) {
    const local1 = a + b;             // line 18
    const local2 = b + c;             // line 19
    const local3 = local1 * local2;   // line 20
    return local3;                     // line 21
}

function main() {
    let x = 5;                         // line 25
    const y = 10;                      // line 26
    const z = 15;                      // line 27
    const pt = new Point(100, 200, "origin");  // line 28
    x = modify(x, 3);                 // line 29
    const result = process(x, y, z);  // line 30
    console.log(`x=${x} result=${result} global=${globalCount}`);  // line 31
    console.log(`pt=(${pt.x},${pt.y},${pt.name})`);               // line 32
}

main();
