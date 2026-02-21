/// The number of data bits per varint byte (the MSB is the continuation flag).
pub const DATA_BITS: u32 = 7;

/// Bitmask for the 7 data bits of a varint byte.
pub const DATA_MASK: u8 = 0x7F;

/// The continuation bit: set in every byte except the last.
pub const CONTINUATION_BIT: u8 = 0x80;

/// Maximum number of bytes a 64-bit varint can occupy (ceil(64/7) = 10).
pub const MAX_VARINT_BYTES: usize = 10;

/// The result of decoding a varint: the value and how many bytes were consumed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeResult {
    pub value: u64,
    pub bytes_read: usize,
}

impl DecodeResult {
    pub fn new(value: u64, bytes_read: usize) -> Self {
        DecodeResult { value, bytes_read }
    }
}

impl std::fmt::Display for DecodeResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "DecodeResult {{ value: {}, bytes_read: {} }}",
            self.value, self.bytes_read
        )
    }
}

/// Format a byte slice as a hex string for debugging.
///
/// Example: `[0xAC, 0x02]` -> `"ac 02"`
pub fn hex_dump(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Calculate the expected number of bytes needed to encode `value`.
pub fn expected_byte_count(value: u64) -> usize {
    if value == 0 {
        return 1;
    }
    let bits = 64 - value.leading_zeros() as usize;
    (bits + DATA_BITS as usize - 1) / DATA_BITS as usize
}
