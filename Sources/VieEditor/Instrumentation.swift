import Darwin
import Foundation

/// Process-level measurements used by the HUD and the benchmark.
public enum Metrics {
    /// Wall time since the kernel started this process (includes dyld and runtime startup).
    public static func secondsSinceProcessStart() -> Double? {
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
    public static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
    }
}

/// A list of timing samples with percentile summaries.
public final class Stats {
    public private(set) var samples: [Double] = []

    public init() {}

    public var count: Int { samples.count }
    public var last: Double { samples.last ?? 0 }
    public var max: Double { samples.max() ?? 0 }

    public func record(_ v: Double) { samples.append(v) }
    public func merge(_ other: Stats) { samples += other.samples }

    public func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        return s[Swift.min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    public func describe(unit: String) -> String {
        String(format: "n=%d  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f %@",
               count, percentile(0.5), percentile(0.95), percentile(0.99), max, unit)
    }
}
