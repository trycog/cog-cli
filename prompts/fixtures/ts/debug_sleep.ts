declare var process: { pid: number };

let counter: number = 0;                       // line 3

function tick(): void {
    counter++;                                 // line 6
    console.log(`tick ${counter}`);            // line 7
}

function sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));  // line 11
}

async function main(): Promise<void> {
    console.log(`pid: ${process.pid}`);        // line 15
    for (let i: number = 0; i < 300; i++) {    // line 16
        tick();                                // line 17
        await sleep(1000);                     // line 18
    }
}

main();
