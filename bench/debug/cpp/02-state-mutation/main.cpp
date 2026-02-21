#include "ring_buffer.h"
#include "message.h"
#include <iostream>

int main() {
    RingBuffer buffer(8);

    int sent = 0;
    int received = 0;
    int corrupted = 0;
    int total_to_send = 1000;

    // Simulate producer/consumer with batch operations.
    // Producer fills the buffer in batches of up to 8,
    // then consumer drains all available messages.
    int msg_id = 0;
    while (sent < total_to_send || received < sent) {
        // Produce a batch of up to 8 messages
        int produced = 0;
        while (sent < total_to_send && produced < 8) {
            Message msg(msg_id, msg_id * 7);  // payload = id * 7
            if (buffer.push(msg)) {
                sent++;
                msg_id++;
                produced++;
            } else {
                break;  // Buffer full
            }
        }

        // Consume all available messages
        Message msg;
        while (buffer.pop(msg)) {
            received++;
            // Verify message integrity: id must be non-negative
            // and payload must equal id * 7
            if (msg.id < 0 || msg.payload != msg.id * 7) {
                corrupted++;
            }
        }
    }

    if (corrupted == 0 && received == total_to_send) {
        std::cout << "Received " << received << "/" << total_to_send
                  << " messages, all correct" << std::endl;
    } else {
        std::cout << "Received " << received << "/" << total_to_send
                  << " messages, " << corrupted << " corrupted" << std::endl;
    }

    return 0;
}
