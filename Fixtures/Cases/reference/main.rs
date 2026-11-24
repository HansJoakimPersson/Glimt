// Rust
use std::collections::HashMap;

fn main() {
    let mut counts: HashMap<&str, u32> = HashMap::new();
    *counts.entry("glimt").or_insert(0) += 1;
    println!("Hej {:?}", counts);
}
