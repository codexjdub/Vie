import AppKit
import QuartzCore

// A Dock-launched app's main thread runs at user-interactive QoS. Started from a shell we may
// inherit a lower class and get scheduled on efficiency cores, which skews every timing.
pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "generate":
    guard args.count >= 3, let mb = Int(args[2]) else {
        print("usage: VieSpike generate <path> <megabytes> [--long-line]")
        exit(2)
    }
    do {
        try Generator.write(path: args[1], megabytes: mb, longLine: args.contains("--long-line"))
        print("wrote \(args[1])")
        exit(0)
    } catch {
        fputs("generate failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case "selftest":
    SelfTest.run()
    exit(0)
default:
    break
}

let options = Options(args)
var rope = Rope()
var openMs = 0.0
if let path = options.path {
    let t0 = CACurrentMediaTime()
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        rope = data.withUnsafeBytes { Rope(bytes: $0.bindMemory(to: UInt8.self)) }
    } catch {
        fputs("can't open \(path): \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    openMs = (CACurrentMediaTime() - t0) * 1000
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(rope: rope, options: options, openMs: openMs)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
