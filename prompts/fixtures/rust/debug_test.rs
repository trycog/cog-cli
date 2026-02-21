fn add(a: i32, b: i32) -> i32 {
    let result = a + b;        // line 2
    result                      // line 3
}

fn multiply(a: i32, b: i32) -> i32 {
    let result = a * b;        // line 7
    result                      // line 8
}

fn compute(x: i32, y: i32) -> i32 {
    let sum = add(x, y);              // line 12
    let product = multiply(x, y);     // line 13
    let final_ = sum + product;       // line 14
    final_                             // line 15
}

fn loop_sum(n: i32) -> i32 {
    let mut total = 0;                 // line 19
    for i in 1..=n {
        total = add(total, i);        // line 21
    }
    total                              // line 23
}

fn factorial(n: i32) -> i32 {
    if n <= 1 {                        // line 27
        return 1;                      // line 28
    }
    n * factorial(n - 1)              // line 30
}

fn main() {
    let x = 10;                                    // line 34
    let y = 20;                                    // line 35
    let result1 = compute(x, y);                  // line 36
    println!("compute = {}", result1);            // line 37
    let result2 = loop_sum(5);                     // line 38
    println!("loop_sum = {}", result2);           // line 39
    let result3 = factorial(5);                    // line 40
    println!("fact = {}", result3);               // line 41
}
