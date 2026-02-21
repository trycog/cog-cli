static GLOBAL_COUNT: i32 = 100;        // line 1

struct Point {                          // line 3
    x: i32,                             // line 4
    y: i32,                             // line 5
    name: String,                       // line 6
}

fn modify(val: &mut i32, delta: i32) {
    *val += delta;                      // line 10
}

fn process(a: i32, b: i32, c: i32) -> i32 {
    let local1 = a + b;                // line 14
    let local2 = b + c;                // line 15
    let local3 = local1 * local2;      // line 16
    local3                              // line 17
}

fn main() {
    let mut x = 5;                      // line 21
    let y = 10;                         // line 22
    let z = 15;                         // line 23
    let pt = Point { x: 100, y: 200, name: String::from("origin") };  // line 24
    modify(&mut x, 3);                  // line 25
    let result = process(x, y, z);     // line 26
    println!("x={} result={} global={}", x, result, GLOBAL_COUNT);     // line 27
    println!("pt=({},{},{})", pt.x, pt.y, pt.name);                    // line 28
}
