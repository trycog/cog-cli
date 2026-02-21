use std::sync::mpsc::sync_channel;
use std::thread;

use crate::stage;
use crate::worker::Record;

/// Channel buffer size -- deliberately small to trigger the deadlock quickly.
///
/// When both the forward channel (stage1 -> stage2) and the feedback channel
/// (stage2 -> stage1) are bounded at this size, a circular dependency forms:
///
///   Stage 1 blocks on  stage1->stage2.send()  (buffer full)
///   Stage 2 blocks on  stage2->stage1.send()  (buffer full)
///
/// Neither can make progress.
///
/// **Fix**: Use `try_send` for the feedback channel and drop records that
/// cannot be sent, or use an unbounded `std::sync::mpsc::channel()` for
/// the feedback path so it never blocks the sender.
const CHANNEL_BOUND: usize = 5;

/// Total records to push through the pipeline.
const NUM_RECORDS: u32 = 500;

/// Configuration for the pipeline (extracted for clarity).
struct PipelineConfig {
    num_records: u32,
    channel_bound: usize,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        PipelineConfig {
            num_records: NUM_RECORDS,
            channel_bound: CHANNEL_BOUND,
        }
    }
}

/// Build and run the 3-stage pipeline, returning collected results.
///
/// The pipeline topology:
///
/// ```text
///   producer --> [input] --> Stage 1 --> [s1_to_s2] --> Stage 2 --> [s2_to_s3] --> Stage 3 --> results
///                                ^                         |
///                                |--- [feedback] ----------|
/// ```
///
/// All channels are `sync_channel` with a small bound, which creates the
/// potential for circular blocking between Stage 1 and Stage 2 via the
/// feedback path.
pub fn run_pipeline() -> Vec<Record> {
    let config = PipelineConfig::default();
    let bound = config.channel_bound;

    // Forward channels (bounded).
    let (input_tx, input_rx) = sync_channel::<Record>(bound);
    let (s1_to_s2_tx, s1_to_s2_rx) = sync_channel::<Record>(bound);
    let (s2_to_s3_tx, s2_to_s3_rx) = sync_channel::<Record>(bound);

    // Feedback channel (bounded -- this is the root cause of the deadlock).
    //
    // FIX: replace with an unbounded channel:
    //   let (feedback_tx, feedback_rx) = std::sync::mpsc::channel::<Record>();
    //
    // or use try_send in stage2 to make it non-blocking:
    //   if feedback_tx.try_send(record).is_err() {
    //       output.send(record).expect("forward failed");
    //   }
    let (feedback_tx, feedback_rx) = sync_channel::<Record>(bound);

    // --- Spawn pipeline stages ---

    let s1 = thread::Builder::new()
        .name("stage-1".into())
        .spawn(move || {
            stage::stage1(input_rx, s1_to_s2_tx, feedback_rx);
        })
        .expect("failed to spawn stage 1");

    let s2 = thread::Builder::new()
        .name("stage-2".into())
        .spawn(move || {
            stage::stage2(s1_to_s2_rx, s2_to_s3_tx, feedback_tx);
        })
        .expect("failed to spawn stage 2");

    let s3 = thread::Builder::new()
        .name("stage-3".into())
        .spawn(move || -> Vec<Record> {
            stage::stage3(s2_to_s3_rx)
        })
        .expect("failed to spawn stage 3");

    // --- Producer: feed records into Stage 1 ---
    for i in 1..=config.num_records {
        let record = Record::new(i);
        input_tx.send(record).expect("producer send failed");
    }
    drop(input_tx); // close the input channel to signal EOF

    // --- Wait for the pipeline to complete ---
    s1.join().expect("stage 1 panicked");
    s2.join().expect("stage 2 panicked");
    let results = s3.join().expect("stage 3 panicked");

    results
}
