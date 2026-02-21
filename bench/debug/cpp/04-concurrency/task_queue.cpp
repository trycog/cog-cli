#include "task_queue.h"

void TaskQueue::push(Task task) {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks_.push_front(std::move(task));
}

bool TaskQueue::pop(Task& task) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (tasks_.empty()) return false;
    task = std::move(tasks_.front());
    tasks_.pop_front();
    return true;
}

bool TaskQueue::steal(Task& task) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (tasks_.empty()) return false;
    task = std::move(tasks_.back());
    tasks_.pop_back();
    return true;
}

bool TaskQueue::empty() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return tasks_.empty();
}

size_t TaskQueue::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return tasks_.size();
}

bool TaskQueue::stealNoLock(Task& task) {
    if (tasks_.empty()) return false;
    task = std::move(tasks_.back());
    tasks_.pop_back();
    return true;
}

bool TaskQueue::emptyNoLock() const {
    return tasks_.empty();
}
