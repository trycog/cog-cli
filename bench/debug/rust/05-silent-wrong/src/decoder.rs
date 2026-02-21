use crate::types::{DecodeResult, CONTINUATION_BIT, DATA_MASK, MAX_VARINT_BYTES};

/// Decode a varint from the front of `bytes`.
///
/// Returns the decoded value and the number of bytes consumed.
///
/// The encoding uses 7 data bits per byte with the MSB as a continuation
/// flag.  Bytes are stored in little-endian order: the first byte carries
/// bits 0..6, the second byte carries bits 7..13, and so on.
///
/// To reconstruct the value, each byte's 7 data bits are shifted left
/// by `shift` and OR-ed into the accumulator.  `shift` should advance
/// by 7 after each byte.
pub fn decode_varint(bytes: &[u8]) -> DecodeResult {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;

    for (i, &byte) in bytes.iter().enumerate() {
        if i >= MAX_VARINT_BYTES {
            // Overlong encoding -- truncate to prevent infinite reads.
            return DecodeResult::new(result, i);
        }

        let data = (byte & DATA_MASK) as u64;
        result |= data << shift;

        // BUG: shift advances by 8 instead of 7.
        //
        // For single-byte varints this doesn't matter (the loop exits
        // before `shift` is used again).  For multi-byte varints the
        // second byte's data bits land at bit 8 instead of bit 7,
        // leaving a gap of one zero bit between each group.  This
        // causes the decoded value to be larger than the original.
        //
        // Example: encoding of 300 is [0xAC, 0x02].
        //   Correct: (0x2C << 0) | (0x02 << 7)  = 44 + 256 = 300
        //   Buggy:   (0x2C << 0) | (0x02 << 8)  = 44 + 512 = 556
        //
        // FIX: change 8 to 7  (i.e., `types::DATA_BITS`).
        shift += 8; // BUG: should be 7

        // Stop when the continuation bit is clear.
        if byte & CONTINUATION_BIT == 0 {
            return DecodeResult::new(result, i + 1);
        }
    }

    // Reached end of buffer while continuation bit was still set.
    DecodeResult::new(result, bytes.len())
}

/// Decode a sequence of concatenated varints from a byte stream.
///
/// Returns a vector of decoded values.  Stops when all bytes are consumed.
pub fn decode_many(bytes: &[u8]) -> Vec<u64> {
    let mut values = Vec::new();
    let mut offset = 0;

    while offset < bytes.len() {
        let result = decode_varint(&bytes[offset..]);
        if result.bytes_read == 0 {
            break; // safety: avoid infinite loop on corrupt data
        }
        values.push(result.value);
        offset += result.bytes_read;
    }

    values
}

/// Decode a single varint from `bytes` starting at `offset`.
///
/// Returns `(value, new_offset)`.  Useful for parsing a stream of varints
/// mixed with other data.
pub fn decode_varint_at(bytes: &[u8], offset: usize) -> (u64, usize) {
    let result = decode_varint(&bytes[offset..]);
    (result.value, offset + result.bytes_read)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_zero() {
        assert_eq!(decode_varint(&[0x00]).value, 0);
    }

    #[test]
    fn decode_127() {
        assert_eq!(decode_varint(&[0x7F]).value, 127);
    }

    #[test]
    fn decode_128_buggy() {
        // With the bug, [0x80, 0x01] decodes to 256 instead of 128.
        //   byte 0: data=0x00, shift=0 -> result=0, shift becomes 8
        //   byte 1: data=0x01, shift=8 -> result = 0 | (1 << 8) = 256
        let r = decode_varint(&[0x80, 0x01]);
        assert_eq!(r.value, 256); // wrong -- should be 128
        assert_eq!(r.bytes_read, 2);
    }

    #[test]
    fn decode_300_buggy() {
        // With the bug, [0xAC, 0x02] decodes to 556 instead of 300.
        //   byte 0: data=0x2C=44, shift=0 -> result=44, shift becomes 8
        //   byte 1: data=0x02, shift=8 -> result = 44 | (2 << 8) = 44 + 512 = 556
        let r = decode_varint(&[0xAC, 0x02]);
        assert_eq!(r.value, 556); // wrong -- should be 300
        assert_eq!(r.bytes_read, 2);
    }

    #[test]
    fn decode_many_values() {
        // Encoded stream: [0x00, 0x7F, 0x80, 0x01]
        // = values 0, 127, 128 (or 256 with bug)
        let values = decode_many(&[0x00, 0x7F, 0x80, 0x01]);
        assert_eq!(values.len(), 3);
        assert_eq!(values[0], 0);
        assert_eq!(values[1], 127);
        // values[2] is 256 (buggy) instead of 128
    }
}
