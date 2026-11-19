import AppKit

@main
@MainActor
enum VieApp {
    static func main() {
        // A Dock-launched app's main thread runs at user-interactive QoS. Started from a shell
        // (benchmarks, `make run`) it may inherit a lower class; ask for the real one.
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

        // Command-line arguments are ours to parse; don't let AppKit treat them as files.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(options: LaunchOptions(Array(CommandLine.arguments.dropFirst())))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
