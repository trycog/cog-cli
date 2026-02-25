declare var process: { argv: string[]; exit(code: number): never; abort(): never };

function divide(a: number, b: number): number {
    if (b === 0) throw new Error("Division by zero");  // line 4
    return Math.floor(a / b);                           // line 5
}

function dereferenceNull(): void {
    const obj: any = null;              // line 9
    console.log(obj.value);            // line 10 — TypeError
}

function abortHandler(): void {
    process.abort();                   // line 14 — SIGABRT
}

function main(): void {
    if (process.argv.length < 3) {                              // line 18
        console.log(`Usage: node ${process.argv[1]} [divzero|null|abort]`);  // line 19
        process.exit(1);                                        // line 20
    }
    const mode: string = process.argv[2];                      // line 22
    console.log(`mode: ${mode}`);                              // line 23
    if (mode.startsWith("d")) {                                // line 24
        divide(10, 0);                                         // line 25
    } else if (mode.startsWith("n")) {                         // line 26
        dereferenceNull();                                     // line 27
    } else if (mode.startsWith("a")) {                         // line 28
        abortHandler();                                        // line 29
    }
}

main();
