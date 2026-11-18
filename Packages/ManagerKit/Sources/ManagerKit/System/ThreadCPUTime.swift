import Darwin

/// Rechenzeit des aufrufenden Threads (`CLOCK_THREAD_CPUTIME_ID`): Grundlage für CPU-Budgets von Arbeit auf einer
/// eigenen Queue oder einem eigenen Thread (Belegung, Komplettprüfung der Code-Bäume).
enum ThreadCPUTime {
    static var now: Duration { .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) }
}
