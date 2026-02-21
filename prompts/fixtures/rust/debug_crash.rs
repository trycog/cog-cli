use std::env;
use std::process;

fn divide(a: i32, b: i32) -> i32 {
    a / b                          // line 5 — will panic when b=0
}

fn dereference_null() {
    let p: *const i32 = std::ptr::null();  // line 9
    unsafe {
        println!("{}", *p);        // line 11 — SIGSEGV
    }
}

fn abort_handler() {
    process::abort();              // line 16 — SIGABRT
}

fn main() {
    let args: Vec<String> = env::args().collect();  // line 20
    if args.len() < 2 {                             // line 21
        println!("Usage: {} [divzero|null|abort]", args[0]);  // line 22
        process::exit(1);                           // line 23
    }
    let mode = &args[1];                            // line 25
    println!("mode: {}", mode);                    // line 26
    if mode.starts_with('d') {                     // line 27
        divide(10, 0);                              // line 28
    } else if mode.starts_with('n') {              // line 29
        dereference_null();                         // line 30
    } else if mode.starts_with('a') {              // line 31
        abort_handler();                            // line 32
    }
}
