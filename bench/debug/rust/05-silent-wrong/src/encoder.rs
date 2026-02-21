use crate::types::{CONTINUATION_BIT, DATA_BITS, DATA_MASK, MAX_VARINT_BYTES};

/// Encode `value` as a variable-length integer (varint).
///
/// Each output byte carries 7 bits of data in the lower bits.
/// The MSB (0x80) is the continuation flag: it is set on every byte
/// except the final one.
///
/// Examples:
///   0       -> [0x00]                  (1 byte)
///   127     -> [0x7F]                  (1 byte)
///   128     -> [0x80, 0x01]            (2 bytes)
///   300     -> [0xAC, 0x02]            (2 bytes)
///   16383   -> [0xFF, 0x7F]            (2 bytes)
///   16384   -> [0x80, 0x80, 0x01]      (3 bytes)
///   65535   -> [0xFF, 0xFF, 0x03]      (3 bytes)
pub fn encode_varint(mut value: u64) -> Vec<u8> {
    let mut buf = Vec::with_capacity(MAX_VARINT_BYTES);

    loop {
        // Take the lowest 7 bits.
        let mut byte = (value & DATA_MASK as u64) as u8;
        value >>= DATA_BITS;

        if value != 0 {
            // More bytes to come -- set the continuation bit.
            byte |= CONTINUATION_BIT;
        }

        buf.push(byte);

        if value == 0 {
            break;
        }
    }

    buf
}

/// Encode `value` into a pre-allocated buffer starting at `offset`.
///
/// Returns the number of bytes written.  Panics if the buffer is too
/// small (fewer than `MAX_VARINT_BYTES` remaining).
pub fn encode_varint_into(mut value: u64, buf: &mut [u8], offset: usize) -> usize {
    let mut i = offset;

    loop {
        assert!(
            i < buf.len(),
            "buffer overflow: need more than {} bytes to encode varint",
            buf.len() - offset
        );

        let mut byte = (value & DATA_MASK as u64) as u8;
        value >>= DATA_BITS;

        if value != 0 {
            byte |= CONTINUATION_BIT;
        }

        buf[i] = byte;
        i += 1;

        if value == 0 {
            break;
        }
    }

    i - offset
}

/// Encode a sequence of values into a single byte stream.
pub fn encode_many(values: &[u64]) -> Vec<u8> {
    let mut buf = Vec::new();
    for &v in values {
        buf.extend(encode_varint(v));
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_zero() {
        assert_eq!(encode_varint(0), vec![0x00]);
    }

    #[test]
    fn encode_single_byte_max() {
        assert_eq!(encode_varint(127), vec![0x7F]);
    }

    #[test]
    fn encode_two_byte_min() {
        assert_eq!(encode_varint(128), vec![0x80, 0x01]);
    }

    #[test]
    fn encode_300() {
        // 300 = 0b100101100
        // Low 7 bits: 0101100 = 0x2C, with continuation: 0xAC
        // Remaining: 0b10 = 2
        assert_eq!(encode_varint(300), vec![0xAC, 0x02]);
    }

    #[test]
    fn encode_two_byte_max() {
        // 16383 = 0b11111111111111 (14 ones)
        // Low 7: 0x7F | 0x80 = 0xFF, high 7: 0x7F
        assert_eq!(encode_varint(16383), vec![0xFF, 0x7F]);
    }

    #[test]
    fn encode_three_bytes() {
        // 65535 = 0xFFFF = 0b1111111111111111
        // Byte 0: bits 0-6 = 1111111 | 0x80 = 0xFF
        // Byte 1: bits 7-13 = 1111111 | 0x80 = 0xFF
        // Byte 2: bits 14-15 = 11 = 0x03
        assert_eq!(encode_varint(65535), vec![0xFF, 0xFF, 0x03]);
    }

    #[test]
    fn encode_into_buffer() {
        let mut buf = [0u8; 16];
        let n = encode_varint_into(300, &mut buf, 0);
        assert_eq!(n, 2);
        assert_eq!(&buf[..2], &[0xAC, 0x02]);
    }

    #[test]
    fn encode_many_values() {
        let values = vec![0, 127, 128, 300];
        let encoded = encode_many(&values);
        assert_eq!(encoded, vec![0x00, 0x7F, 0x80, 0x01, 0xAC, 0x02]);
    }
}
