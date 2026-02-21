use std::thread;
use std::time::Duration;

static mut COUNTER: i32 = 0;          // line 4

fn tick() {
    unsafe {
        COUNTER += 1;                  // line 8
        println!("tick {}", COUNTER);  // line 9
    }
}

fn main() {
    println!("pid: {}", std::process::id());  // line 14
    for _ in 0..300 {                          // line 15
        tick();                                // line 16
        thread::sleep(Duration::from_secs(1)); // line 17
    }
}
