#include "thread_pool.h"
#include <iostream>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <unistd.h>
#include <thread>

int main() {
    const int NUM_TASKS = 500;
    std::atomic<int> completed(0);

    // Watchdog: if the program hangs for more than 10 seconds, report
    // the deadlock and force-exit the process.
    std::thread watchdog([&]() {
        std::this_thread::sleep_for(std::chrono::seconds(10));
        if (completed.load() < NUM_TASKS) {
            std::cout << "TIMEOUT: Completed " << completed.load()
                      << "/" << NUM_TASKS << " tasks" << std::endl;
            _exit(1);
        }
    });
    watchdog.detach();

    {
        ThreadPool pool(4);

        // Submit tasks unevenly: all go to queue 0.
        // Threads 1, 2, and 3 start with empty queues, so they must
        // steal from queue 0 (and each other once tasks migrate).
        // This forces concurrent work-stealing, which triggers the
        // lock-ordering deadlock in trySteal.
        for (int i = 0; i < NUM_TASKS; i++) {
            pool.submitTo(0, [&completed]() {
                // Simulate a moderate amount of work.
                volatile int x = 0;
                for (int j = 0; j < 10000; j++) x += j;
                completed++;
            });
        }

        // Wait for all tasks to finish (or timeout)
        auto start = std::chrono::steady_clock::now();
        while (completed.load() < NUM_TASKS) {
            auto elapsed = std::chrono::steady_clock::now() - start;
            if (std::chrono::duration_cast<std::chrono::seconds>(elapsed).count() > 10) {
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    }

    if (completed.load() == NUM_TASKS) {
        std::cout << "Completed " << completed.load() << " tasks" << std::endl;
    } else {
        std::cout << "TIMEOUT: Completed " << completed.load()
                  << "/" << NUM_TASKS << " tasks" << std::endl;
    }

    return 0;
}
