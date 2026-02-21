mod types;
mod encoder;
mod decoder;

use types::{expected_byte_count, hex_dump};
use encoder::encode_varint;
use decoder::decode_varint;

/// Test values spanning the range from 1-byte to multi-byte varints.
///
/// Single-byte values (0-127) will roundtrip correctly even with the bug
/// because the shift error only affects multi-byte decoding.
const TEST_VALUES: [u64; 10] = [
    0,      // 1 byte
    1,      // 1 byte
    127,    // 1 byte  (maximum single-byte value)
    128,    // 2 bytes (minimum two-byte value)
    255,    // 2 bytes
    256,    // 2 bytes
    300,    // 2 bytes
    1000,   // 2 bytes
    16383,  // 2 bytes (maximum two-byte value)
    65535,  // 3 bytes
];

/// Run the roundtrip test: encode each value, decode, compare.
fn main() {
    let mut failures: Vec<RoundtripFailure> = Vec::new();

    println!("=== Varint Roundtrip Test ===");
    println!();

    for &original in &TEST_VALUES {
        let encoded = encode_varint(original);
        let decoded = decode_varint(&encoded);

        let expected_bytes = expected_byte_count(original);
        let ok = decoded.value == original;

        if !ok {
            failures.push(RoundtripFailure {
                original,
                decoded: decoded.value,
                encoded_hex: hex_dump(&encoded),
                expected_bytes,
                actual_bytes: decoded.bytes_read,
            });
        }
    }

    // Print detailed results.
    if failures.is_empty() {
        println!("Roundtrip OK: all {} values match", TEST_VALUES.len());
    } else {
        for f in &failures {
            println!(
                "FAIL: {} -> [{}] ({} bytes) -> {}",
                f.original, f.encoded_hex, f.actual_bytes, f.decoded
            );
        }
        println!();
        println!(
            "Roundtrip FAIL: {} of {} values incorrect",
            failures.len(),
            TEST_VALUES.len()
        );
    }
}

/// Details of a single roundtrip failure for reporting.
#[allow(dead_code)]
struct RoundtripFailure {
    original: u64,
    decoded: u64,
    encoded_hex: String,
    expected_bytes: usize,
    actual_bytes: usize,
}
