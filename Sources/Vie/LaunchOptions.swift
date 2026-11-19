import CoreGraphics

/// Command-line options. Plain paths open files; the flags are developer tools.
struct LaunchOptions: Sendable {
    var paths: [String] = []
    /// Run the scripted benchmark on the first file, print results, quit.
    var bench = false
    /// Print time to first frame, quit.
    var launchOnly = false
    /// Show the draw-time HUD and print timing stats on quit.
    var hud = false
    /// Time rendering into an offscreen bitmap at this scale (simulated Retina).
    var scale: CGFloat?
    /// Line the benchmark's typing phase edits (default: middle of the file).
    var typeLine: Int?

    var isMeasuring: Bool { bench || launchOnly }

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--bench": bench = true
            case "--launch": launchOnly = true
            case "--hud": hud = true
            case "--scale":
                i += 1
                if i < args.count, let s = Double(args[i]) { scale = CGFloat(s) }
            case "--type-line":
                i += 1
                if i < args.count { typeLine = Int(args[i]) }
            default:
                if arg.hasPrefix("--") || arg.hasPrefix("-psn_") {
                    break // unknown flag
                } else if arg.hasPrefix("-") {
                    i += 1 // AppKit-style "-Key value" user-defaults pair
                } else {
                    paths.append(arg)
                }
            }
            i += 1
        }
    }
}
