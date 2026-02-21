use crate::types::{DecodeResult, CONTINUATION_BIT, DATA_BITS, DATA_MASK, MAX_VARINT_BYTES};

/// Decode a varint from the front of `bytes`.
///
/// Returns the decoded value and the number of bytes consumed.
///
/// The encoding uses 7 data bits per byte with the MSB as a continuation
/// flag.  Bytes are stored in little-endian order: the first byte carries
/// bits 0..6, the second byte carries bits 7..13, and so on.
///
/// To reconstruct the value, each byte's data bits are shifted left
/// by `shift` and OR-ed into the accumulator.
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

        shift += DATA_BITS;

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
    fn decode_many_values() {
        let values = decode_many(&[0x00, 0x7F, 0x80, 0x01]);
        assert_eq!(values.len(), 3);
        assert_eq!(values[0], 0);
        assert_eq!(values[1], 127);
    }
}
