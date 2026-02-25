"use strict";

let globalCount: number = 100;                 // line 3

class Point {                                  // line 5
    x: number;                                 // line 6
    y: number;                                 // line 7
    name: string;                              // line 8
    constructor(x: number, y: number, name: string) {
        this.x = x;                            // line 10
        this.y = y;                            // line 11
        this.name = name;                      // line 12
    }
}

function modify(val: number, delta: number): number {
    return val + delta;                        // line 17
}

function processData(a: number, b: number, c: number): number {
    const local1: number = a + b;              // line 21
    const local2: number = b + c;              // line 22
    const local3: number = local1 * local2;    // line 23
    return local3;                             // line 24
}

function main(): void {
    let x: number = 5;                         // line 28
    const y: number = 10;                      // line 29
    const z: number = 15;                      // line 30
    const pt: Point = new Point(100, 200, "origin");  // line 31
    x = modify(x, 3);                         // line 32
    const result: number = processData(x, y, z);  // line 33
    console.log(`x=${x} result=${result} global=${globalCount}`);  // line 34
    console.log(`pt=(${pt.x},${pt.y},${pt.name})`);               // line 35
}

main();
