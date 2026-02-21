"use strict";

let counter = 0;                       // line 3

function tick() {
    counter++;                         // line 6
    console.log(`tick ${counter}`);    // line 7
}

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));  // line 11
}

async function main() {
    console.log(`pid: ${process.pid}`);    // line 15
    for (let i = 0; i < 300; i++) {        // line 16
        tick();                             // line 17
        await sleep(1000);                 // line 18
    }
}

main();
