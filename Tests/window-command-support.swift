// Shared fixtures for the window-command and window-display harnesses.
import CoreGraphics
import Foundation

@MainActor
enum Tally {
    static var failures = 0
    static var passes = 0

    static func finish() {
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        Tally.passes += 1
    } else {
        Tally.failures += 1
        print("FAIL: \(message)")
    }
}

@MainActor func expectRect(_ actual: CGRect, _ expected: CGRect, _ message: String) {
    if actual == expected {
        Tally.passes += 1
    } else {
        Tally.failures += 1
        print("FAIL: \(message) — got \(actual), expected \(expected)")
    }
}

/// The reference display: origin at the AX origin, evenly divisible by halves and thirds.
let mainScreen = WindowPlacementEngine.Screen(
    id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))

func screens(_ list: WindowPlacementEngine.Screen...) -> [WindowPlacementEngine.Screen] { list }

func placement(
    _ command: WindowCommand.ID, on screen: WindowPlacementEngine.Screen = mainScreen,
    window: CGRect = CGRect(x: 100, y: 100, width: 600, height: 400), gap: CGFloat = 0,
    step: Int = 0, cycle: WindowCycle = .off, restore: CGRect? = nil,
    lastTile: WindowCommand.ID? = nil,
    allScreens: [WindowPlacementEngine.Screen]? = nil
) -> WindowPlacementEngine.Placement? {
    WindowPlacementEngine.placement(
        for: WindowPlacementEngine.Input(
            command: command, windowFrame: window, screens: allScreens ?? [screen], gap: gap,
            step: step, cycle: cycle, restoreFrame: restore, lastTileCommand: lastTile))
}

func frame(
    _ command: WindowCommand.ID, on screen: WindowPlacementEngine.Screen = mainScreen,
    window: CGRect = CGRect(x: 100, y: 100, width: 600, height: 400), gap: CGFloat = 0,
    step: Int = 0, cycle: WindowCycle = .off, restore: CGRect? = nil,
    lastTile: WindowCommand.ID? = nil,
    allScreens: [WindowPlacementEngine.Screen]? = nil
) -> CGRect? {
    placement(
        command, on: screen, window: window, gap: gap, step: step, cycle: cycle,
        restore: restore, lastTile: lastTile, allScreens: allScreens)?.frame
}

/// Presses `command` like `WindowMover`: each press starts from where the last one landed.
func presses(
    _ command: WindowCommand.ID, _ count: Int, from window: CGRect,
    on list: [WindowPlacementEngine.Screen]
) -> [WindowPlacementEngine.Placement] {
    let clock = Date(timeIntervalSince1970: 1_000_000)
    var memory = WindowActionMemory<Int>()
    var current = window
    var landed: [WindowPlacementEngine.Placement] = []
    for _ in 0..<count {
        let host = WindowPlacementEngine.screen(containing: current, in: list)!
        let decision = memory.decide(
            key: 1, command: command, currentFrame: current, currentScreenID: host.id,
            cycleLength: length(command, .displays, list), now: clock)
        let placement = WindowPlacementEngine.placement(
            for: WindowPlacementEngine.Input(
                command: command, windowFrame: current, screens: list, step: decision.step,
                cycle: .displays, originScreenID: decision.originScreenID))!
        memory.commit(
            key: 1, command: command, decision: decision, appliedFrame: placement.frame,
            screenID: placement.screenID, now: clock)
        current = placement.frame
        landed.append(placement)
    }
    return landed
}

func length(
    _ command: WindowCommand.ID, _ cycle: WindowCycle,
    _ list: [WindowPlacementEngine.Screen] = [mainScreen]
) -> Int {
    WindowPlacementEngine.cycleLength(for: command, screens: list, cycle: cycle)
}
