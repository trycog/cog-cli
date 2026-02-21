#ifndef THREAD_POOL_H
#define THREAD_POOL_H

#include "task_queue.h"
#include <vector>
#include <thread>
#include <atomic>
#include <memory>

class ThreadPool {
public:
    explicit ThreadPool(size_t numThreads);
    ~ThreadPool();

    void submit(TaskQueue::Task task);
    void submitTo(size_t queueIdx, TaskQueue::Task task);
    void waitAll();

private:
    void workerLoop(size_t id);
    bool trySteal(size_t thiefId, TaskQueue::Task& task);

    std::vector<std::thread> threads_;
    std::vector<std::unique_ptr<TaskQueue>> queues_;
    std::atomic<bool> running_;
    std::atomic<int> pendingTasks_;
    size_t numThreads_;
};

#endif
