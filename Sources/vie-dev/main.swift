import Foundation

let usage = """
    usage: vie-dev generate <path> <megabytes> [--long-line]
      Writes a deterministic test file: source-like code, or one giant JSON line.

    """

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "generate":
    guard args.count >= 3, let megabytes = Int(args[2]) else {
        fputs(usage, stderr)
        exit(2)
    }
    do {
        try Generator.write(path: args[1], megabytes: megabytes, longLine: args.contains("--long-line"))
        print("wrote \(args[1])")
    } catch {
        fputs("generate failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
default:
    fputs(usage, stderr)
    exit(2)
}
