// Standalone contract tests for display moves, the display cycle, restore and action memory.
import CoreGraphics
import Foundation

@main
@MainActor
struct WindowDisplayTests {
    static func main() {
        testDisplays()
        testDisplayCycle()
        testRestore()
        testMemory()
        testFuzz()
        Tally.finish()
    }

    // MARK: - Displays

    static func testDisplays() {
        expect(frame(.nextDisplay) == nil, "a single display makes Next Display a no-op")
        expect(frame(.previousDisplay) == nil, "a single display makes Previous Display a no-op")

        let left = mainScreen
        let right = WindowPlacementEngine.Screen(
            id: 2, frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1440))
        // Deliberately out of order, to prove the ordering is derived and not inherited.
        let both = screens(right, left)
        expect(WindowPlacementEngine.ordered(both).map(\.id) == [1, 2], "displays order left-to-right")

        let leftHalfOnLeft = frame(.leftHalf, on: left)!
        let onRight = frame(
            .nextDisplay, window: leftHalfOnLeft, allScreens: both)!
        expectRect(
            onRight, CGRect(x: 1440, y: 0, width: 1280, height: 1440),
            "a left half maps proportionally onto the larger display")
        expect(right.visibleFrame.contains(onRight), "the moved window stays inside the destination")

        expectRect(
            frame(.previousDisplay, window: onRight, allScreens: both)!, leftHalfOnLeft,
            "next then previous round-trips to the original frame")

        // Wrapping in both directions.
        expect(
            WindowPlacementEngine.placement(
                for: WindowPlacementEngine.Input(
                    command: .previousDisplay, windowFrame: leftHalfOnLeft, screens: both)
            )?.screenID == 2, "previous from the first display wraps to the last")
        expect(
            WindowPlacementEngine.placement(
                for: WindowPlacementEngine.Input(command: .nextDisplay, windowFrame: onRight, screens: both)
            )?.screenID == 1, "next from the last display wraps to the first")

        // A remembered tile is re-derived exactly on the destination, gaps included.
        expectRect(
            frame(.nextDisplay, window: leftHalfOnLeft, gap: 10, lastTile: .leftHalf, allScreens: both)!,
            frame(.leftHalf, on: right, gap: 10)!,
            "a remembered tile is re-derived exactly on the destination")
        expectRect(
            frame(
                .nextDisplay, window: frame(.firstThird, on: left)!, lastTile: .firstThird,
                allScreens: both)!,
            frame(.firstThird, on: right)!,
            "a remembered third is re-derived exactly on the destination")

        // Screen resolution by overlap.
        expect(
            WindowPlacementEngine.screen(
                containing: CGRect(x: 1150, y: 0, width: 500, height: 100), in: both)?.id == 1,
            "a straddling window belongs to the display showing more of it")
        expect(
            WindowPlacementEngine.screen(
                containing: CGRect(x: 1300, y: 0, width: 500, height: 100), in: both)?.id == 2,
            "the overlap majority flips with the window")
        expect(
            WindowPlacementEngine.screen(
                containing: CGRect(x: -5000, y: -5000, width: 100, height: 100), in: both) != nil,
            "a window off every display still resolves to one")
    }

    // MARK: - Cycling across displays

    static func testDisplayCycle() {
        let left = mainScreen
        let right = WindowPlacementEngine.Screen(
            id: 2, frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 900))
        let both = screens(right, left)
        let onLeft = CGRect(x: 100, y: 100, width: 600, height: 400)

        // The strip is two half-slots per display, so the length is a plain product.
        expect(length(.leftHalf, .off, both) == 1, "cycling off is a length of one")
        expect(length(.leftHalf, .sizes, both) == 3, "the size cycle is three steps")
        expect(length(.leftHalf, .displays, both) == 4, "two displays give four slots")
        expect(length(.maximize, .displays, both) == 1, "a non-cycling command never cycles")
        expect(
            length(.leftHalf, .displays) == 1,
            "one display makes the display leg a no-op")

        // The sequence the issue asks for: Left walks the strip backwards, wrapping.
        let expected: [CGRect] = [
            frame(.leftHalf, on: left)!, frame(.rightHalf, on: right)!,
            frame(.leftHalf, on: right)!, frame(.rightHalf, on: left)!
        ]
        for (step, want) in expected.enumerated() {
            expectRect(
                frame(.leftHalf, window: onLeft, step: step, cycle: .displays, allScreens: both)!,
                want, "left half display step \(step)")
        }
        expectRect(
            frame(.leftHalf, window: onLeft, step: 4, cycle: .displays, allScreens: both)!,
            expected[0], "the display cycle wraps")
        expectRect(
            frame(.leftHalf, window: onLeft, step: -1, cycle: .displays, allScreens: both)!,
            expected[3], "a negative display step normalises")

        // Right is the exact mirror, so the two shortcuts sweep the strip in opposite directions.
        for (step, want) in [
            frame(.rightHalf, on: left)!, frame(.leftHalf, on: right)!,
            frame(.rightHalf, on: right)!, frame(.leftHalf, on: left)!
        ].enumerated() {
            expectRect(
                frame(.rightHalf, window: onLeft, step: step, cycle: .displays, allScreens: both)!,
                want, "right half display step \(step)")
        }

        // Top and Bottom walk the same strip, keeping their own axis.
        expectRect(
            frame(.topHalf, window: onLeft, step: 1, cycle: .displays, allScreens: both)!,
            frame(.bottomHalf, on: right)!, "top half step 1 is the bottom half of the next display")
        expectRect(
            frame(.bottomHalf, window: onLeft, step: 1, cycle: .displays, allScreens: both)!,
            frame(.topHalf, on: right)!, "bottom half step 1 is the top half of the next display")

        // The size cycle stays on the host display, whatever else is plugged in.
        for step in 0..<3 {
            expectRect(
                frame(.leftHalf, window: onLeft, step: step, cycle: .sizes, allScreens: both)!,
                frame(.leftHalf, on: left, step: step, cycle: .sizes)!,
                "the size cycle ignores the other display at step \(step)")
        }

        // Real presses: from the second one on, the window sits on a display it was just moved to.
        let onRight = CGRect(x: 1540, y: 100, width: 600, height: 400)
        let walked = presses(.leftHalf, 5, from: onRight, on: both).map(\.frame)
        let walk: [CGRect] = [
            frame(.leftHalf, on: right)!, frame(.rightHalf, on: left)!,
            frame(.leftHalf, on: left)!, frame(.rightHalf, on: right)!,
            frame(.leftHalf, on: right)!
        ]
        for (press, want) in walk.enumerated() {
            expectRect(walked[press], want, "left half from the right display, press \(press + 1)")
        }

        // An origin that is no longer plugged in falls back to the window's own display.
        expectRect(
            WindowPlacementEngine.placement(
                for: WindowPlacementEngine.Input(
                    command: .leftHalf, windowFrame: onLeft, screens: both, step: 1,
                    cycle: .displays, originScreenID: 99))!.frame,
            expected[1], "an unplugged origin counts from the host")

        // One full lap of real presses visits every slot exactly once, from either starting display.
        for start in [onLeft, onRight] {
            for command in [WindowCommand.ID.leftHalf, .rightHalf] {
                let lap = presses(command, length(command, .displays, both), from: start, on: both)
                expect(
                    Set(lap.map(\.frame)).count == lap.count,
                    "\(command.rawValue) visits four distinct slots")
                expect(
                    Set(lap.map(\.screenID)) == [1, 2],
                    "\(command.rawValue) reaches both displays")
            }
        }

        // The gap belongs to the destination, not to the display the window started on.
        let narrow = WindowPlacementEngine.Screen(
            id: 3, frame: CGRect(x: 1440, y: 0, width: 200, height: 900),
            visibleFrame: CGRect(x: 1440, y: 0, width: 200, height: 900))
        expectRect(
            frame(
                .leftHalf, window: onLeft, gap: 100, step: 2, cycle: .displays,
                allScreens: screens(left, narrow))!,
            frame(.leftHalf, on: narrow, gap: 100)!,
            "the destination display sanitises the gap")

        // No mode ever gives a non-cycling command a chain to walk.
        for command in WindowCommand.ID.allCases
        where !WindowCommandCatalog.cyclesOnRepeat.contains(command) {
            for cycle in WindowCycle.allCases {
                expect(
                    length(command, cycle, both) == 1,
                    "\(command.rawValue) has no cycle to walk under \(cycle.rawValue)")
            }
        }
    }

    // MARK: - Restore

    static func testRestore() {
        expect(frame(.restore) == nil, "restore with no recorded frame does nothing")

        let recorded = CGRect(x: 123, y: 234, width: 456, height: 321)
        expectRect(
            frame(.restore, restore: recorded)!, recorded, "a valid restore frame comes back untouched")

        // A restore point stranded off every display is recovered.
        let stranded = CGRect(x: 9000, y: 9000, width: 400, height: 300)
        let recovered = frame(.restore, restore: stranded)!
        expect(recovered.size == stranded.size, "a stranded restore keeps its size")
        expect(
            mainScreen.visibleFrame.contains(recovered), "a stranded restore lands back on screen")
        expect(
            recovered.midX == mainScreen.visibleFrame.midX,
            "a stranded restore is re-centred horizontally")
    }

    // MARK: - Action memory

    static func testMemory() {
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let half = CGRect(x: 0, y: 0, width: 720, height: 900)
        let original = CGRect(x: 100, y: 100, width: 600, height: 400)

        // A fresh window: step 0, nothing to restore, the current frame is the anchor.
        var memory = WindowActionMemory<Int>()
        var decision = memory.decide(
            key: 1, command: .leftHalf, currentFrame: original, currentScreenID: 1,
            cycleLength: 3, now: clock)
        expect(decision.step == 0, "a first press starts at step 0")
        expect(!decision.canRestore, "a never-seen window has nothing to restore to")
        expectRect(decision.restoreFrame, original, "the first press captures the original frame")
        expect(decision.originScreenID == 1, "a first press starts its chain on its own display")
        memory.commit(
            key: 1, command: .leftHalf, decision: decision, appliedFrame: half, screenID: 1,
            now: clock)

        // Repeats advance the cycle and never disturb the restore point.
        for expected in [1, 2, 0, 1] {
            let applied = frame(.leftHalf, step: expected)!
            decision = memory.decide(
                key: 1, command: .leftHalf, currentFrame: memory.record(for: 1)!.appliedFrame,
                currentScreenID: 1, cycleLength: 3, now: clock)
            expect(decision.step == expected, "the cycle advances to step \(expected)")
            expectRect(decision.restoreFrame, original, "the restore point survives step \(expected)")
            expect(decision.canRestore, "a seen window can be restored")
            memory.commit(
                key: 1, command: .leftHalf, decision: decision, appliedFrame: applied, screenID: 1,
                now: clock)
        }

        // A different command, screen, or window resets the cycle.
        decision = memory.decide(
            key: 1, command: .rightHalf, currentFrame: memory.record(for: 1)!.appliedFrame,
            currentScreenID: 1, cycleLength: 3, now: clock)
        expect(decision.step == 0, "a different command restarts the cycle")
        expectRect(decision.restoreFrame, original, "a different command keeps the restore point")
        decision = memory.decide(
            key: 1, command: .leftHalf, currentFrame: memory.record(for: 1)!.appliedFrame,
            currentScreenID: 2, cycleLength: 3, now: clock)
        expect(decision.step == 0, "a different display restarts the cycle")
        expect(decision.originScreenID == 2, "a restarted chain starts on the current display")
        decision = memory.decide(
            key: 99, command: .leftHalf, currentFrame: original, currentScreenID: 1,
            cycleLength: 3, now: clock)
        expect(decision.step == 0 && !decision.canRestore, "another window has its own chain")

        // A chain the display cycle carried elsewhere keeps counting from where it started.
        var crossing = WindowActionMemory<Int>()
        let crossingSeed = crossing.decide(
            key: 1, command: .leftHalf, currentFrame: original, currentScreenID: 1,
            cycleLength: 4, now: clock)
        crossing.commit(
            key: 1, command: .leftHalf, decision: crossingSeed, appliedFrame: half, screenID: 2,
            now: clock)
        decision = crossing.decide(
            key: 1, command: .leftHalf, currentFrame: half, currentScreenID: 2, cycleLength: 4,
            now: clock)
        expect(decision.step == 1, "a press on the display the chain landed on continues it")
        expect(decision.originScreenID == 1, "a continued chain keeps its origin display")

        // A user drag resets the cycle and re-anchors the restore point.
        var dragged = WindowActionMemory<Int>()
        let seed = dragged.decide(
            key: 1, command: .leftHalf, currentFrame: original, currentScreenID: 1,
            cycleLength: 3, now: clock)
        dragged.commit(
            key: 1, command: .leftHalf, decision: seed, appliedFrame: half, screenID: 1, now: clock)
        let movedByUser = CGRect(x: 400, y: 400, width: 500, height: 300)
        decision = dragged.decide(
            key: 1, command: .leftHalf, currentFrame: movedByUser, currentScreenID: 1,
            cycleLength: 3, now: clock)
        expect(decision.step == 0, "a user drag restarts the cycle")
        expectRect(decision.restoreFrame, movedByUser, "a user drag re-anchors the restore point")
        expect(decision.lastTileCommand == nil, "a user drag forgets the remembered tile")

        // A quantising app that lands a point off its target must NOT read as a user drag.
        let quantised = CGRect(x: half.minX + 1, y: half.minY, width: half.width - 1, height: half.height)
        decision = dragged.decide(
            key: 1, command: .leftHalf, currentFrame: quantised, currentScreenID: 1,
            cycleLength: 3, now: clock)
        expect(decision.step == 1, "a sub-tolerance difference keeps the cycle running")
        expect(decision.lastTileCommand == .leftHalf, "an untouched tile is remembered")

        // The cycle switch pins everything to step 0.
        var pinned = WindowActionMemory<Int>()
        var pinnedDecision = pinned.decide(
            key: 1, command: .leftHalf, currentFrame: original, currentScreenID: 1,
            cycleLength: 1, now: clock)
        for _ in 0..<5 {
            pinned.commit(
                key: 1, command: .leftHalf, decision: pinnedDecision, appliedFrame: half,
                screenID: 1, now: clock)
            pinnedDecision = pinned.decide(
                key: 1, command: .leftHalf, currentFrame: half, currentScreenID: 1,
                cycleLength: 1, now: clock)
            expect(pinnedDecision.step == 0, "cycling off pins every repeat to step 0")
        }

        // A non-cycling command never advances even with cycling on.
        var nonCycling = WindowActionMemory<Int>()
        let maximized = mainScreen.visibleFrame
        var nonDecision = nonCycling.decide(
            key: 1, command: .maximize, currentFrame: original, currentScreenID: 1,
            cycleLength: length(.maximize, .sizes), now: clock)
        for _ in 0..<5 {
            nonCycling.commit(
                key: 1, command: .maximize, decision: nonDecision, appliedFrame: maximized,
                screenID: 1, now: clock)
            nonDecision = nonCycling.decide(
                key: 1, command: .maximize, currentFrame: maximized, currentScreenID: 1,
                cycleLength: length(.maximize, .sizes), now: clock)
            expect(nonDecision.step == 0, "a non-cycling command never advances")
        }

        var timed = WindowActionMemory<Int>(cycleTimeout: 60)
        let timedSeed = timed.decide(
            key: 1, command: .leftHalf, currentFrame: original, currentScreenID: 1,
            cycleLength: 3, now: clock)
        timed.commit(
            key: 1, command: .leftHalf, decision: timedSeed, appliedFrame: half, screenID: 1,
            now: clock)
        expect(
            timed.decide(
                key: 1, command: .leftHalf, currentFrame: half, currentScreenID: 1,
                cycleLength: 3, now: clock.addingTimeInterval(30)
            ).step == 1, "a cycle inside the timeout continues")
        expect(
            timed.decide(
                key: 1, command: .leftHalf, currentFrame: half, currentScreenID: 1,
                cycleLength: 3, now: clock.addingTimeInterval(120)
            ).step == 0, "a cycle past the timeout restarts")

        // The restore point survives a run of different commands, then Restore is idempotent.
        var run = WindowActionMemory<Int>()
        var runDecision = run.decide(
            key: 1, command: .leftHalf, currentFrame: original, currentScreenID: 1,
            cycleLength: 3, now: clock)
        run.commit(
            key: 1, command: .leftHalf, decision: runDecision, appliedFrame: half, screenID: 1,
            now: clock)
        var applied = half
        for command in [WindowCommand.ID.maximize, .topRightQuarter, .centerThird] {
            runDecision = run.decide(
                key: 1, command: command, currentFrame: applied, currentScreenID: 1,
                cycleLength: 3, now: clock)
            applied = frame(command)!
            run.commit(
                key: 1, command: command, decision: runDecision, appliedFrame: applied, screenID: 1,
                now: clock)
        }
        runDecision = run.decide(
            key: 1, command: .restore, currentFrame: applied, currentScreenID: 1, cycleLength: 3,
            now: clock)
        expectRect(
            runDecision.restoreFrame, original, "the restore point survives three other commands")
        expect(runDecision.canRestore, "the window can be restored after a run of commands")
        let restored = frame(.restore, restore: runDecision.restoreFrame)!
        expectRect(restored, original, "restore returns the true original frame")
        run.commit(
            key: 1, command: .restore, decision: runDecision, appliedFrame: restored, screenID: 1,
            now: clock)
        let second = run.decide(
            key: 1, command: .restore, currentFrame: restored, currentScreenID: 1,
            cycleLength: 3, now: clock)
        expectRect(
            frame(.restore, restore: second.restoreFrame)!, original, "a second restore is idempotent")

        // Fullscreen breaks the cycle chain but keeps the restore point.
        run.forgetCycle(key: 1)
        expect(run.record(for: 1)?.step == 0, "forgetCycle resets the step")
        expect(
            run.record(for: 1)?.originScreenID == run.record(for: 1)?.screenID,
            "forgetCycle restarts the chain on the window's current display")
        expectRect(
            run.record(for: 1)!.restoreFrame, original, "forgetCycle keeps the restore point")

        // Bounded growth, most-recently-used retained.
        var bounded = WindowActionMemory<Int>(capacity: 64)
        for key in 0..<100 {
            let boundedDecision = bounded.decide(
                key: key, command: .leftHalf, currentFrame: original, currentScreenID: 1,
                cycleLength: 3, now: clock)
            bounded.commit(
                key: key, command: .leftHalf, decision: boundedDecision, appliedFrame: half,
                screenID: 1, now: clock)
        }
        expect(bounded.count == 64, "the memory is bounded at its capacity")
        expect(bounded.record(for: 99) != nil, "the most recent key survives eviction")
        expect(bounded.record(for: 0) == nil, "the oldest key is evicted")
        expect(bounded.record(for: 36) != nil, "the 64 most recent keys survive")

        bounded.forget { $0 % 2 == 0 }
        expect(bounded.record(for: 99) != nil, "forget(where:) keeps non-matching keys")
        expect(bounded.record(for: 98) == nil, "forget(where:) drops matching keys")
        bounded.forget(key: 99)
        expect(bounded.record(for: 99) == nil, "forget(key:) drops that key")
    }

    // MARK: - Fuzz

    static func testFuzz() {
        let displays: [[WindowPlacementEngine.Screen]] = [
            [mainScreen],
            [
                mainScreen,
                WindowPlacementEngine.Screen(
                    id: 2, frame: CGRect(x: 1440, y: -200, width: 2560, height: 1440),
                    visibleFrame: CGRect(x: 1440, y: -175, width: 2560, height: 1390))
            ],
            [
                WindowPlacementEngine.Screen(
                    id: 5, frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                    visibleFrame: CGRect(x: 0, y: 25, width: 1024, height: 590)),
                WindowPlacementEngine.Screen(
                    id: 6, frame: CGRect(x: -3840, y: 0, width: 3840, height: 2160),
                    visibleFrame: CGRect(x: -3840, y: 25, width: 3840, height: 2060))
            ]
        ]
        let windows: [CGRect] = [
            CGRect(x: 100, y: 100, width: 600, height: 400),
            CGRect(x: 0, y: 0, width: 0, height: 0),
            CGRect(x: -900, y: -900, width: 200, height: 150),
            CGRect(x: 200, y: 200, width: 5000, height: 4000),
            CGRect(x: 1439, y: 899, width: 1, height: 1)
        ]
        let gaps: [CGFloat] = [0, 1, 8, 25, 200]
        let cycles: [WindowCycle] = WindowCycle.allCases
        let steps = [0, 1, 5, -3]

        var checked = 0
        var problems: [String] = []
        for screens in displays {
            for window in windows {
                for gap in gaps {
                    for cycle in cycles {
                        for step in steps {
                            for command in WindowCommand.ID.allCases {
                                let input = WindowPlacementEngine.Input(
                                    command: command, windowFrame: window, screens: screens, gap: gap,
                                    step: step, cycle: cycle, restoreFrame: window, lastTileCommand: nil)
                                // A nil placement is a legitimate quiet no-op, not a failure.
                                guard let placement = WindowPlacementEngine.placement(for: input) else {
                                    continue
                                }
                                checked += 1
                                let rect = placement.frame
                                let label = "\(command.rawValue) gap \(gap) step \(step) window \(window)"

                                if !(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite
                                    && rect.height.isFinite)
                                {
                                    problems.append("non-finite frame: \(label)")
                                }
                                if rect.width < 0 || rect.height < 0 {
                                    problems.append("negative size: \(label)")
                                }
                                guard let host = screens.first(where: { $0.id == placement.screenID })
                                else {
                                    problems.append("unknown screen id: \(label)")
                                    continue
                                }
                                if rect.intersection(host.visibleFrame).isNull {
                                    problems.append("off-screen frame: \(label)")
                                }
                                // Determinism, and no drift when a command is applied twice at step 0.
                                if WindowPlacementEngine.placement(for: input)?.frame != rect {
                                    problems.append("non-deterministic: \(label)")
                                }
                                var repeated = input
                                repeated.windowFrame = rect
                                // Only step 0 is meant to be idempotent: a cycle exists to move the window.
                                if step == 0,
                                    let again = WindowPlacementEngine.placement(for: repeated)?.frame,
                                    command != .makeLarger, command != .makeSmaller, command != .moveLeft,
                                    command != .moveRight, command != .moveUp, command != .moveDown,
                                    command != .nextDisplay, command != .previousDisplay,
                                    again != rect
                                {
                                    problems.append("drifts on repeat: \(label) — \(rect) then \(again)")
                                }
                            }
                        }
                    }
                }
            }
        }
        expect(checked > 1000, "the fuzz sweep exercised a meaningful number of placements")
        expect(problems.isEmpty, "fuzz sweep found no violations")
        for problem in problems.prefix(10) { print("      \(problem)") }
    }
}
