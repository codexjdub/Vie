import AppKit
import VieWorkspace

/// A copy, a Duplicate, or a move to another disk, done off the main thread so the window
/// keeps working: waiting its turn, or running. Stopping one (`cancel`) leaves things as if it
/// hadn't started: what it copied is removed, and a move's originals stay where they were.
final class TreeTransfer: @unchecked Sendable {
    /// Copies `source` to `target` (which must not exist) with progress in bytes; false if stopped.
    typealias Copier = @Sendable (URL, URL, @escaping (Int64) -> Void, @escaping () -> Bool) throws -> Bool
    /// The bytes a transfer copies, counted until told to stop.
    typealias Sizer = @Sendable ([URL], () -> Bool) -> Int64

    enum Kind { case copy, duplicate, move }

    let kind: Kind
    /// Each item and where it goes: for a move its new place, for a copy the folder (the copy's
    /// name is picked when its turn comes, so nothing is replaced).
    let items: [(source: URL, destination: URL)]
    /// The Undo menu's name for it.
    let actionName: String

    private let lock = NSLock()
    private var cancelled = false
    private var lastReport = 0.0

    // Main thread only:
    /// The bytes to copy, nil while they're being counted.
    var total: Int64?
    var done: Int64 = 0
    /// The progress bar was shown for it (it took a while).
    var wasShown = false

    init(kind: Kind, items: [(URL, URL)], actionName: String) {
        self.kind = kind
        self.items = items.map { (source: $0.0, destination: $0.1) }
        self.actionName = actionName
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    /// Whether to pass progress on now: at most ten times a second.
    func reportDue() -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastReport >= 0.1 else { return false }
            lastReport = now
            return true
        }
    }
}

/// What a transfer did: what it placed where, and what went wrong.
struct TransferResult: @unchecked Sendable {
    /// Copies: each item and its copy; moves: each item's old and new place.
    var placed: [(from: URL, to: URL)] = []
    var errors: [Error] = []
    var cancelled = false
}

extension FileTreeController {
    // MARK: - Transfers in the background

    /// A copy or a move is running or waiting (closing the window asks first).
    var isBusy: Bool { !transfers.isEmpty }

    /// Puts a transfer in line; it starts at once if nothing else is running.
    func enqueue(_ transfer: TreeTransfer) {
        transfers.append(transfer)
        if transfers.count == 1 { startNext() } else { updateTransferBar() }
    }

    /// Waits until every transfer has finished (or been stopped).
    func finishTransfers() async {
        guard !transfers.isEmpty else { return }
        await withCheckedContinuation { transferWaiters.append($0) }
    }

    /// Stops the running transfer and drops those waiting, and waits until the running one
    /// has cleaned up after itself.
    func stopTransfers() async {
        guard let running = transfers.first else { return }
        running.cancel()
        transfers = [running]
        await finishTransfers()
    }

    /// What a transfer is doing, for the progress bar and the question before closing:
    /// “Copying “photos”” or “Moving 3 items”.
    func describe(_ transfer: TreeTransfer) -> String {
        let verb = transfer.kind == .move ? "Moving" : "Copying"
        let what = transfer.items.count == 1 ? "“\(transfer.items[0].source.lastPathComponent)”" : "\(transfer.items.count) items"
        return "\(verb) \(what)"
    }

    private func startNext() {
        guard let transfer = transfers.first else {
            setTransferBar(shown: false)
            let waiters = transferWaiters
            transferWaiters = []
            for w in waiters { w.resume() }
            return
        }
        let copier = copier, sizer = sizer
        let report: @Sendable (Int64?, Int64, Bool) -> Void = { [weak self] total, done, now in
            guard now || transfer.reportDue() else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.progressed(transfer, total: total, done: done) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + progressDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transfers.first === transfer else { return }
                transfer.wasShown = true
                self.setTransferBar(shown: true)
            }
        }
        if progressDelay <= 0 {
            transfer.wasShown = true
            setTransferBar(shown: true)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.run(transfer, copier: copier, sizer: sizer, report: report)
            await self?.finished(transfer, result)
        }
    }

    /// The work, off the main thread: counts the bytes, copies each item, and for a move
    /// removes the originals once all are copied and unchanged.
    private nonisolated static func run(_ t: TreeTransfer, copier: TreeTransfer.Copier, sizer: TreeTransfer.Sizer,
                                        report: @escaping @Sendable (Int64?, Int64, Bool) -> Void) -> TransferResult {
        let total = sizer(t.items.map(\.source)) { t.isCancelled }
        report(total, 0, true)
        var result = TransferResult()
        var made: [(from: URL, to: URL)] = []
        var snapshots: [[String: [Int64]]] = []
        var finished: Int64 = 0
        for item in t.items {
            if t.isCancelled { break }
            let target = t.kind == .move ? item.destination : FileTreeController.freeName(for: item.source, in: item.destination)
            let snapshot = t.kind == .move ? FileCopy.snapshot(of: item.source) : [:]
            var copied: Int64 = 0
            do {
                let base = finished
                guard try copier(item.source, target, { bytes in
                    copied = bytes
                    report(total, base + bytes, false)
                }, { t.isCancelled }) else { break }
            } catch {
                result.errors.append(error)
                break
            }
            finished += copied
            made.append((item.source, target))
            snapshots.append(snapshot)
        }
        // Stopped, or a move that failed part way: as if it hadn't started.
        if t.isCancelled || (t.kind == .move && !result.errors.isEmpty) {
            for m in made { try? FileManager.default.removeItem(at: m.to) }
            result.cancelled = t.isCancelled
            return result
        }
        guard t.kind == .move else {
            result.placed = made
            return result
        }
        for (m, snapshot) in zip(made, snapshots) {
            // Saved (or otherwise changed) while it was copied: the copy would be out of date.
            guard FileCopy.snapshot(of: m.from) == snapshot else {
                try? FileManager.default.removeItem(at: m.to)
                result.errors.append(FileTreeError.changedWhileMoving(m.from.lastPathComponent))
                continue
            }
            do {
                try FileManager.default.removeItem(at: m.from)
                result.placed.append(m)
            } catch {
                result.errors.append(error)
            }
        }
        return result
    }

    private func progressed(_ transfer: TreeTransfer, total: Int64?, done: Int64) {
        guard transfers.first === transfer else { return }
        if let total { transfer.total = total }
        transfer.done = done
        updateTransferBar()
    }

    /// Back on the main thread: what the transfer placed is shown and selected (a single
    /// Duplicate gets the name field), Undo takes it back, and the next one starts.
    private func finished(_ transfer: TreeTransfer, _ result: TransferResult) {
        if let i = transfers.firstIndex(where: { $0 === transfer }) { transfers.remove(at: i) }
        let placed = result.placed
        if !placed.isEmpty {
            var folders: Set<String> = []
            for m in placed { folders.insert(m.to.deletingLastPathComponent().standardizedFileURL.path) }
            if transfer.kind == .move {
                for m in placed { folders.insert(m.from.deletingLastPathComponent().standardizedFileURL.path) }
            }
            for folder in folders.sorted() { refreshFolder(URL(fileURLWithPath: folder, isDirectory: true)) }
            let name = transfer.actionName
            switch transfer.kind {
            case .move:
                let moves = placed.map { Move(from: $0.from, to: $0.to) }
                for m in moves { onRename?(m.from, m.to) }
                let back = moves.reversed().map { Move(from: $0.to, to: $0.from) }
                registerUndo(name) { $0.move(back, actionName: name) }
            case .copy, .duplicate:
                let copies = placed.map(\.to)
                registerUndo(name) { $0.trash(copies, actionName: name) }
            }
            select(placed.map(\.to))
            // The name field, unless the copy took long enough that the keyboard may be elsewhere.
            if transfer.kind == .duplicate, placed.count == 1, !transfer.wasShown || outline.window?.firstResponder === outline,
               let node = tree.node(for: placed[0].to) {
                beginRename(node)
            }
        }
        if let error = result.errors.first { onError?(error) }
        startNext()
    }

    // MARK: - The progress bar

    private func setTransferBar(shown: Bool) {
        let scroll = outline.enclosingScrollView
        if shown {
            updateTransferBar()
            guard transferBar.superview == nil else { return }
            let h = TransferBar.height
            transferBar.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: h)
            transferBar.autoresizingMask = [.width, .maxYMargin]
            view.addSubview(transferBar)
            scroll?.frame = NSRect(x: 0, y: h, width: view.bounds.width, height: max(0, view.bounds.height - h))
        } else if transferBar.superview != nil {
            transferBar.removeFromSuperview()
            scroll?.frame = view.bounds
        }
    }

    private func updateTransferBar() {
        guard let transfer = transfers.first else { return }
        var detail: String
        if let total = transfer.total {
            detail = total > 0 ? "\(Self.bytes(min(transfer.done, total))) of \(Self.bytes(total))" : ""
            transferBar.setProgress(total > 0 ? Double(min(transfer.done, total)) / Double(total) : nil)
        } else {
            detail = "Preparing…"
            transferBar.setProgress(nil)
        }
        let waiting = transfers.count - 1
        if waiting > 0 { detail += (detail.isEmpty ? "" : " · ") + "\(waiting) more waiting" }
        transferBar.title.stringValue = describe(transfer)
        transferBar.detail.stringValue = detail
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// Whether `item` and `folder` are on different disks (by their volumes).
    nonisolated static func onOtherDisk(_ item: URL, _ folder: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let a = volume(item.deletingLastPathComponent()), let b = volume(folder) else { return false }
        return !a.isEqual(b)
    }
}

/// The bar at the bottom of the sidebar while a copy or move takes a while: what's being
/// done, how far along it is, what's waiting, and a button to stop it.
final class TransferBar: NSView {
    static let height: CGFloat = 46
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let indicator = NSProgressIndicator()
    let stopButton = NSButton()
    var onStop: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        indicator.style = .bar
        indicator.controlSize = .small
        indicator.minValue = 0
        indicator.maxValue = 1
        stopButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop")
        stopButton.isBordered = false
        stopButton.imagePosition = .imageOnly
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.toolTip = "Stop"
        stopButton.target = self
        stopButton.action = #selector(stopClicked(_:))
        for v in [title, detail, indicator, stopButton] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A fraction done, or nil while it isn't known (an indeterminate bar).
    func setProgress(_ fraction: Double?) {
        if let fraction {
            if indicator.isIndeterminate {
                indicator.stopAnimation(nil)
                indicator.isIndeterminate = false
            }
            indicator.doubleValue = fraction
        } else if !indicator.isIndeterminate {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
        }
    }

    @objc private func stopClicked(_ sender: Any?) { onStop?() }

    override func layout() {
        super.layout()
        let b = bounds, pad: CGFloat = 10, button: CGFloat = 16
        let textWidth = max(0, b.width - pad * 3 - button)
        title.frame = NSRect(x: pad, y: b.height - 8 - 14, width: textWidth, height: 14)
        indicator.frame = NSRect(x: pad, y: b.height - 8 - 14 - 10, width: textWidth, height: 8)
        detail.frame = NSRect(x: pad, y: 5, width: textWidth, height: 12)
        stopButton.frame = NSRect(x: b.width - pad - button, y: (b.height - button) / 2, width: button, height: button)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
