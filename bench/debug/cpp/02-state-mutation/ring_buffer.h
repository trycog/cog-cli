#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include "message.h"
#include <cstddef>

class RingBuffer {
public:
    RingBuffer(size_t capacity);
    ~RingBuffer();

    bool push(const Message& msg);
    bool pop(Message& msg);
    bool isEmpty() const;
    bool isFull() const;
    size_t size() const;

private:
    Message* buffer;
    size_t capacity;
    size_t head;   // read position
    size_t tail;   // write position
    size_t count;
};

#endif
