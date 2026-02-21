use std::sync::mpsc::{Receiver, SyncSender};

use crate::worker::{do_work, Record};

/// The maximum pipeline stage at which records can still be retried.
/// Once a record's stage reaches this value, it is forwarded to the
/// next stage regardless of its retry eligibility.
const MAX_RETRY_STAGE: u32 = 4;

/// Stage 1: Ingestion.
///
/// Reads raw records from `input`, processes them, and forwards to
/// Stage 2 via `output`.  Also listens for feedback from Stage 2 on
/// `feedback_rx` and re-processes those records.
///
/// **Deadlock trigger**: `output` is a bounded `sync_channel`.  When
/// Stage 1 tries to send on `output` while `output` is full, it blocks.
/// Meanwhile Stage 2 is trying to send feedback on `feedback_tx` (also
/// bounded), which blocks because Stage 1 isn't draining `feedback_rx`.
/// Circular wait = deadlock.
///
/// The design flaw is that this function drains ALL input records in the
/// first loop, only reading feedback AFTER the input is exhausted.
/// During the first loop, feedback_rx is never polled.  If the feedback
/// channel fills up, Stage 2 blocks sending feedback, which backs up
/// the s1-to-s2 channel, which blocks this function.
pub fn stage1(
    input: Receiver<Record>,
    output: SyncSender<Record>,
    feedback_rx: Receiver<Record>,
) {
    let mut records_sent = 0u32;
    let mut feedback_processed = 0u32;

    // --- Primary loop: drain all input records ---
    // BUG: This loop does not interleave checking feedback_rx.
    //      If the feedback channel is bounded, a circular wait
    //      forms once the feedback buffer fills.
    for mut record in input {
        do_work(&mut record, "stage1");
        output.send(record).expect("stage1 -> stage2 send failed");
        records_sent += 1;
    }

    // --- Feedback loop: reprocess records that Stage 2 sent back ---
    // In the deadlocked scenario, we never reach this loop because the
    // primary loop above is stuck on `output.send()`.
    for mut record in feedback_rx {
        record.mark_retry();
        do_work(&mut record, "stage1-redo");
        output.send(record).expect("stage1 -> stage2 redo send failed");
        feedback_processed += 1;
    }

    // Drop the output sender to signal downstream that Stage 1 is done.
    drop(output);

    eprintln!(
        "[stage1] finished: sent={}, feedback={}",
        records_sent, feedback_processed
    );
}

/// Stage 2: Transformation.
///
/// Reads from Stage 1, transforms records, and forwards to Stage 3.
/// Records whose id is divisible by 10 are sent back to Stage 1 for
/// reprocessing via `feedback_tx`, simulating a "needs retry" signal.
///
/// The retry only happens while the record's `stage` is below
/// `MAX_RETRY_STAGE`, preventing infinite loops.
pub fn stage2(
    input: Receiver<Record>,
    output: SyncSender<Record>,
    feedback_tx: SyncSender<Record>,
) {
    let mut forwarded = 0u32;
    let mut feedback_sent = 0u32;

    for mut record in input {
        do_work(&mut record, "stage2");

        let needs_retry = record.id % 10 == 0 && record.stage < MAX_RETRY_STAGE;

        if needs_retry {
            // BUG PATH: this send blocks when the feedback channel is full.
            // Stage 1 can't drain it because Stage 1 is blocked trying to
            // send to US (the s1-to-s2 channel is also full).
            feedback_tx
                .send(record)
                .expect("stage2 -> stage1 feedback send failed");
            feedback_sent += 1;
        } else {
            output.send(record).expect("stage2 -> stage3 send failed");
            forwarded += 1;
        }
    }

    drop(feedback_tx);
    drop(output);

    eprintln!(
        "[stage2] finished: forwarded={}, feedback={}",
        forwarded, feedback_sent
    );
}

/// Stage 3: Output / collection.
///
/// Collects all processed records into a vector.  Also performs a basic
/// integrity check on each record as it arrives.
pub fn stage3(input: Receiver<Record>) -> Vec<Record> {
    let mut results = Vec::new();
    let mut integrity_errors = 0u32;

    for record in input {
        if !record.verify() {
            integrity_errors += 1;
            eprintln!(
                "[stage3] integrity error on record {}: checksum mismatch",
                record.id
            );
        }
        results.push(record);
    }

    eprintln!(
        "[stage3] finished: collected={}, integrity_errors={}",
        results.len(),
        integrity_errors
    );

    results
}
