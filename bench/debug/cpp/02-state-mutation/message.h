#ifndef MESSAGE_H
#define MESSAGE_H

struct Message {
    int id;
    int payload;

    Message() : id(-1), payload(0) {}
    Message(int id, int payload) : id(id), payload(payload) {}

    bool isValid() const { return id >= 0; }
};

#endif
