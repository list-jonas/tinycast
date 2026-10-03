import Foundation

/// How a run ended, once it has.
struct CommandOutcome: Sendable {
    let summary: String
    /// The nudge for a failure the reader can fix, when the exit status names one.
    let hint: String?
    let succeeded: Bool
    let finishedAt: Date
}

/// One run of one command, from the moment it starts.
struct CommandRun: Identifiable, Sendable {
    let id = UUID()
    /// Which custom command this was, so the window can run it again.
    let commandID: UUID
    let name: String
    /// The shell text, shown under the name — "brew" alone says nothing about what ran.
    let commandText: String
    let symbol: String
    let startedAt: Date
    /// Everything printed so far, for copying and for a redraw from scratch.
    var log = ""
    /// One step on means the view appends this rather than walking the whole log.
    var delta = ""
    var revision = 0
    /// Bumped when the head of `log` is dropped, which is the text view's cue to redraw whole.
    var generation = 0
    /// Nil while the command is still running.
    var outcome: CommandOutcome?

    var isRunning: Bool { outcome == nil }

    /// Past `limit` the head is dropped: the tail is where a command says how it went.
    mutating func append(_ text: String, limit: Int) {
        log += text
        delta = text
        revision += 1
        guard log.utf8.count > limit else { return }
        log = String(log.suffix(limit / 2))
        // The delta no longer describes the change, so the view is told to redraw instead.
        generation += 1
    }
}

/// One window, reused: a second run replaces what it shows and never cancels the first.
@MainActor
@Observable
final class CommandOutputPresenter {
    private static let logLimit = 256 * 1024

    private(set) var run: CommandRun?

    @ObservationIgnored private let activation: ActivationPolicy
    @ObservationIgnored private let rerun: (UUID) -> Void
    @ObservationIgnored private let stop: (UUID) -> Void
    @ObservationIgnored private let openSettings: () -> Void
    @ObservationIgnored private lazy var window = AppWindowController(
        title: "Command Output", contentSize: CommandOutputView.initialSize, resizable: true,
        autosaveName: "CommandOutputWindow", activation: activation, closesOnEscape: true)

    init(
        activation: ActivationPolicy, rerun: @escaping (UUID) -> Void,
        stop: @escaping (UUID) -> Void, openSettings: @escaping () -> Void
    ) {
        self.activation = activation
        self.rerun = rerun
        self.stop = stop
        self.openSettings = openSettings
    }

    /// Opens the window on an empty, running command and returns the id the run reports against.
    @discardableResult
    func begin(commandID: UUID, name: String, commandText: String, symbol: String) -> UUID {
        let run = CommandRun(
            commandID: commandID, name: name, commandText: commandText, symbol: symbol,
            startedAt: Date())
        self.run = run
        window.show { CommandOutputView(presenter: self) }
        return run.id
    }

    /// Mutates in place, so a long log is not copied on every streamed chunk.
    func append(_ text: String, to id: UUID) {
        guard run?.id == id else { return }
        run?.append(text, limit: Self.logLimit)
    }

    func finish(_ outcome: CommandOutcome, for id: UUID) {
        guard run?.id == id else { return }
        run?.outcome = outcome
    }

    func runAgain() {
        guard let run else { return }
        rerun(run.commandID)
    }

    func stopRunning() {
        guard let run, run.isRunning else { return }
        stop(run.id)
    }

    func showCommandSettings() {
        openSettings()
    }

    /// Re-raise an open output window; false when none is up, so a reopen falls through.
    func focusExisting() -> Bool {
        window.focus()
    }
}
