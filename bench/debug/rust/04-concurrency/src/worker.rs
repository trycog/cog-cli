/// A processed record flowing through the pipeline.
#[derive(Debug, Clone)]
pub struct Record {
    pub id: u32,
    pub payload: String,
    pub stage: u32,
    pub checksum: u32,
    pub retry_count: u32,
}

impl Record {
    pub fn new(id: u32) -> Self {
        let payload = format!("data-{:04}", id);
        let checksum = compute_checksum(&payload);
        Record {
            id,
            payload,
            stage: 0,
            checksum,
            retry_count: 0,
        }
    }

    /// Advance the record to the next pipeline stage.
    pub fn advance(&mut self) {
        self.stage += 1;
    }

    /// Mark this record as having been retried via the feedback loop.
    pub fn mark_retry(&mut self) {
        self.retry_count += 1;
    }

    /// Verify that the checksum still matches the payload.
    pub fn verify(&self) -> bool {
        compute_checksum(&self.payload) == self.checksum
    }
}

/// Simple checksum: sum of all bytes mod 2^32.
fn compute_checksum(data: &str) -> u32 {
    data.bytes().fold(0u32, |acc, b| acc.wrapping_add(b as u32))
}

/// Simulate a small amount of CPU work by transforming the record's
/// payload and updating the checksum.
pub fn do_work(record: &mut Record, stage_name: &str) {
    record.payload = format!(
        "{} [{}:s{}:r{}]",
        record.payload, stage_name, record.stage, record.retry_count
    );
    record.checksum = compute_checksum(&record.payload);
    record.advance();
}

/// Validate a batch of output records, returning the number of valid
/// records and a list of any that failed validation.
pub fn validate_batch(records: &[Record]) -> (usize, Vec<u32>) {
    let mut valid = 0;
    let mut invalid_ids = Vec::new();

    for record in records {
        if record.verify() {
            valid += 1;
        } else {
            invalid_ids.push(record.id);
        }
    }

    (valid, invalid_ids)
}

/// Check that every record id from 1..=expected_count appears
/// exactly once in the output (no duplicates, no missing).
pub fn check_completeness(records: &[Record], expected_count: u32) -> (Vec<u32>, Vec<u32>) {
    let mut seen = vec![0u32; expected_count as usize + 1];
    for record in records {
        if record.id as usize <= expected_count as usize {
            seen[record.id as usize] += 1;
        }
    }

    let mut missing = Vec::new();
    let mut duplicates = Vec::new();

    for id in 1..=expected_count {
        match seen[id as usize] {
            0 => missing.push(id),
            1 => {} // correct
            _ => duplicates.push(id),
        }
    }

    (missing, duplicates)
}
