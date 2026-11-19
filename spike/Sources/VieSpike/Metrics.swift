import Darwin
import Foundation

enum Metrics {
    /// Wall time since the kernel started this process (includes dyld and runtime startup).
    static func secondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return Double(now.tv_sec - start.tv_sec) + Double(now.tv_usec - start.tv_usec) / 1e6
    }

    /// Physical memory footprint in MB (the number Activity Monitor shows as "Memory").
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

final class Stats {
    private(set) var samples: [Double] = []

    var count: Int { samples.count }
    var last: Double { samples.last ?? 0 }
    var max: Double { samples.max() ?? 0 }

    func record(_ v: Double) { samples.append(v) }
    func merge(_ other: Stats) { samples += other.samples }

    func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        return s[Swift.min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    func describe(unit: String) -> String {
        String(format: "n=%d  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f %@",
               count, percentile(0.5), percentile(0.95), percentile(0.99), max, unit)
    }
}
