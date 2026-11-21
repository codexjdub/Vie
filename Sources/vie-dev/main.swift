import Foundation

let usage = """
    usage: vie-dev generate <path> <megabytes> [--long-line]
      Writes a deterministic test file: source-like code, or one giant JSON line.
    usage: vie-dev generate-repo <folder> <files>
      Writes a synthetic repository of empty files (with ignored folders).
    usage: vie-dev workspace-bench <folder>
      Times the file tree, the ⌘P scan and index, and fuzzy matching per keystroke.
    usage: vie-dev syntax-bench <file>
      Times highlighting: first parse and its memory, reparses after edits, spans per screen.

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
case "generate-repo":
    guard args.count >= 3, let count = Int(args[2]) else {
        fputs(usage, stderr)
        exit(2)
    }
    do {
        try RepoBench.generate(path: args[1], count: count)
    } catch {
        fputs("generate-repo failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case "workspace-bench":
    guard args.count >= 2 else {
        fputs(usage, stderr)
        exit(2)
    }
    RepoBench.run(path: args[1])
case "syntax-bench":
    guard args.count >= 2 else {
        fputs(usage, stderr)
        exit(2)
    }
    SyntaxBench.run(path: args[1])
default:
    fputs(usage, stderr)
    exit(2)
}
