#ifndef TASK_QUEUE_H
#define TASK_QUEUE_H

#include <deque>
#include <mutex>
#include <functional>

class TaskQueue {
public:
    using Task = std::function<void()>;

    void push(Task task);
    bool pop(Task& task);
    bool steal(Task& task);
    bool empty() const;
    size_t size() const;

    // Internal (no-lock) variants for use when caller already holds mutex
    bool stealNoLock(Task& task);
    bool emptyNoLock() const;

    std::mutex& getMutex() { return mutex_; }

private:
    std::deque<Task> tasks_;
    mutable std::mutex mutex_;
};

#endif
