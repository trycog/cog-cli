#include "ring_buffer.h"

RingBuffer::RingBuffer(size_t cap)
    : capacity(cap), head(0), tail(0), count(0) {
    buffer = new Message[capacity];
}

RingBuffer::~RingBuffer() {
    delete[] buffer;
}

bool RingBuffer::push(const Message& msg) {
    if (isFull()) {
        return false;
    }

    buffer[tail] = msg;
    tail = (tail + 1) % capacity;
    count++;
    return true;
}

bool RingBuffer::pop(Message& msg) {
    if (isEmpty()) {
        return false;
    }

    msg = buffer[head];
    // BUG: head wraps at (capacity + 1) instead of capacity.
    // When capacity=8, head advances 0,1,2,...,7,8 instead of 0,...,7,0.
    // On the 9th pop, head=8 which is out of bounds for the array.
    // This causes reads from uninitialized/garbage memory.
    head = (head + 1) % (capacity + 1);
    count--;
    return true;
}

bool RingBuffer::isEmpty() const {
    return count == 0;
}

bool RingBuffer::isFull() const {
    return count == capacity;
}

size_t RingBuffer::size() const {
    return count;
}
