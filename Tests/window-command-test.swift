// Standalone contract tests for the pure window-command catalog and its geometry.
import CoreGraphics
import Foundation

@main
@MainActor
struct WindowCommandTests {
    static func main() {
        testCatalog()
        testConventionLock()
        testTiling()
        testNonDivisible()
        testOffOriginScreens()
        testGaps()
        testSizing()
        testLargerSmaller()
        testNudges()
        Tally.finish()
    }

    // MARK: - Catalog

    static func testCatalog() {
        let commands = WindowCommandCatalog.all
        expect(commands.count == 35, "catalog contains all 35 agreed commands")
        expect(commands.map(\.id) == WindowCommand.ID.allCases, "catalog covers every ID once")
        expect(
            Set(commands.map { $0.name.lowercased() }).count == commands.count, "names are unique")
        expect(commands.allSatisfy { !$0.name.isEmpty }, "names are non-empty")
        expect(commands.allSatisfy { !$0.sfSymbol.isEmpty }, "symbols are non-empty")

        for command in commands {
            expect(
                WindowCommandCatalog.command(forEntryID: command.entryID) == command,
                "\(command.id.rawValue) round-trips through its entry ID")
            expect(
                WindowCommandCatalog.command(id: command.id) == command,
                "\(command.id.rawValue) round-trips through its ID")
            expect(
                command.entryID.hasPrefix("window-command:"),
                "\(command.id.rawValue) is namespaced")
        }
        expect(
            WindowCommandCatalog.command(forEntryID: "window-command:unknown") == nil,
            "unknown entry IDs are rejected")
        expect(
            WindowCommandCatalog.command(forEntryID: "system-action:sleep") == nil,
            "system-action entry IDs are not claimed")

        let cycling = Set(commands.filter(\.cyclesOnRepeat).map(\.id))
        expect(
            cycling == [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
            "only the four halves cycle on repeat")
        let moveOnly = Set(commands.filter { !$0.resizes }.map(\.id))
        expect(
            moveOnly == [.moveLeft, .moveRight, .moveUp, .moveDown],
            "only the four nudges leave the size alone")
        expect(
            Set(commands.filter { $0.kind == .fullscreen }.map(\.id)) == [.toggleFullscreen],
            "only Toggle Fullscreen is a fullscreen command")
        expect(
            Set(commands.filter { $0.kind == .restore }.map(\.id)) == [.restore],
            "only Restore is a restore command")
        expect(
            Set(commands.filter { $0.kind == .space }.map(\.id)) == [.previousSpace, .nextSpace],
            "only the two Space switches are space commands")
        expect(
            commands.filter { $0.kind == .space }.allSatisfy {
                WindowPlacementEngine.placement(
                    for: WindowPlacementEngine.Input(
                        command: $0.id, windowFrame: mainScreen.frame, screens: [mainScreen],
                        gap: 0, step: 0, restoreFrame: nil, lastTileCommand: nil)) == nil
            },
            "a space command resolves no placement, so the mover writes nothing")

        // Grouping drives the Settings list; every command must land in exactly one group.
        let grouped = WindowCommandCatalog.grouped()
        expect(
            grouped.flatMap(\.commands).count == commands.count, "grouping loses no command")
        expect(
            grouped.map(\.group) == WindowCommand.Group.allCases,
            "every group is represented, in declaration order")
        expect(grouped.first { $0.group == .halves }?.commands.count == 4, "four halves")
        expect(grouped.first { $0.group == .quarters }?.commands.count == 4, "four quarters")
        expect(grouped.first { $0.group == .fourths }?.commands.count == 2, "two fourths")
        expect(grouped.first { $0.group == .thirds }?.commands.count == 5, "five thirds")
        expect(grouped.first { $0.group == .sizing }?.commands.count == 11, "eleven sizing commands")
        expect(grouped.first { $0.group == .moving }?.commands.count == 6, "six moving commands")
        expect(grouped.first { $0.group == .spaces }?.commands.count == 2, "two space commands")

        expect(
            WindowPlacementEngine.isTileCommand(.leftHalf)
                && WindowPlacementEngine.isTileCommand(.centerHalf),
            "halves and center half are tiles")
        expect(
            !WindowPlacementEngine.isTileCommand(.maximize)
                && !WindowPlacementEngine.isTileCommand(.moveLeft),
            "free-floating commands are not tiles")

        // Fullscreen has no geometry: the mover branches before asking for a placement.
        expect(frame(.toggleFullscreen) == nil, "Toggle Fullscreen produces no placement")
    }

    // MARK: - Convention lock

    static func testConventionLock() {
        // AX space: +Y points down, so the top half starts at the visible frame's minY.
        expect(
            frame(.topHalf)?.minY == mainScreen.visibleFrame.minY,
            "top half is anchored at visibleFrame.minY (AX space, +Y down)")
        expect(
            frame(.bottomHalf)?.maxY == mainScreen.visibleFrame.maxY,
            "bottom half is anchored at visibleFrame.maxY")
        expect(
            frame(.topLeftQuarter)?.minY == mainScreen.visibleFrame.minY,
            "top left quarter sits at the top")
    }

    // MARK: - Tiling

    static func testTiling() {
        expectRect(frame(.leftHalf)!, CGRect(x: 0, y: 0, width: 720, height: 900), "left half")
        expectRect(frame(.rightHalf)!, CGRect(x: 720, y: 0, width: 720, height: 900), "right half")
        expectRect(frame(.topHalf)!, CGRect(x: 0, y: 0, width: 1440, height: 450), "top half")
        expectRect(
            frame(.bottomHalf)!, CGRect(x: 0, y: 450, width: 1440, height: 450), "bottom half")

        expectRect(
            frame(.topLeftQuarter)!, CGRect(x: 0, y: 0, width: 720, height: 450), "top left quarter")
        expectRect(
            frame(.topRightQuarter)!, CGRect(x: 720, y: 0, width: 720, height: 450),
            "top right quarter")
        expectRect(
            frame(.bottomLeftQuarter)!, CGRect(x: 0, y: 450, width: 720, height: 450),
            "bottom left quarter")
        expectRect(
            frame(.bottomRightQuarter)!, CGRect(x: 720, y: 450, width: 720, height: 450),
            "bottom right quarter")

        let quarters = [
            frame(.topLeftQuarter)!, frame(.topRightQuarter)!, frame(.bottomLeftQuarter)!,
            frame(.bottomRightQuarter)!
        ]
        expect(
            quarters.reduce(CGRect.null) { $0.union($1) } == mainScreen.visibleFrame,
            "the four quarters union to the visible frame")
        var overlapping = false
        for i in quarters.indices {
            for j in quarters.indices where j > i {
                if !quarters[i].intersection(quarters[j]).isEmpty { overlapping = true }
            }
        }
        expect(!overlapping, "quarters never overlap")

        expectRect(
            frame(.firstThreeFourths)!, CGRect(x: 0, y: 0, width: 1080, height: 900),
            "first three fourths")
        expectRect(
            frame(.lastThreeFourths)!, CGRect(x: 360, y: 0, width: 1080, height: 900),
            "last three fourths")
        expect(
            frame(.firstThreeFourths)!.union(frame(.lastThreeFourths)!) == mainScreen.visibleFrame,
            "the two three-fourths cover the screen between them")
        expect(
            frame(.firstThreeFourths)!.intersection(frame(.lastThreeFourths)!) == frame(.centerHalf)!,
            "they overlap on exactly the centre half, so all three share the quarter grid")

        expectRect(frame(.firstThird)!, CGRect(x: 0, y: 0, width: 480, height: 900), "first third")
        expectRect(
            frame(.centerThird)!, CGRect(x: 480, y: 0, width: 480, height: 900), "center third")
        expectRect(frame(.lastThird)!, CGRect(x: 960, y: 0, width: 480, height: 900), "last third")
        expectRect(
            frame(.firstTwoThirds)!, CGRect(x: 0, y: 0, width: 960, height: 900), "first two thirds")
        expectRect(
            frame(.lastTwoThirds)!, CGRect(x: 480, y: 0, width: 960, height: 900), "last two thirds")

        expect(
            frame(.firstThird)!.union(frame(.lastTwoThirds)!) == mainScreen.visibleFrame,
            "first third and last two thirds partition the screen")
        expect(
            frame(.firstTwoThirds)!.union(frame(.lastThird)!) == mainScreen.visibleFrame,
            "first two thirds and last third partition the screen")

        // Size cycling: halves only, ½ → ⅓ → ⅔, wrapping.
        expectRect(
            frame(.leftHalf, step: 1, cycle: .sizes)!, frame(.firstThird)!,
            "left half step 1 is a third")
        expectRect(
            frame(.leftHalf, step: 2, cycle: .sizes)!, frame(.firstTwoThirds)!,
            "left half step 2 is two thirds")
        expectRect(
            frame(.leftHalf, step: 3, cycle: .sizes)!, frame(.leftHalf)!,
            "left half step 3 wraps to the half")
        expectRect(
            frame(.rightHalf, step: 1, cycle: .sizes)!, frame(.lastThird)!,
            "right half step 1 is a third")
        expectRect(
            frame(.rightHalf, step: 2, cycle: .sizes)!, frame(.lastTwoThirds)!,
            "right half step 2 is two thirds")
        expectRect(
            frame(.topHalf, step: 1, cycle: .sizes)!, CGRect(x: 0, y: 0, width: 1440, height: 300),
            "top half step 1 is a vertical third")
        expectRect(
            frame(.topHalf, step: 2, cycle: .sizes)!, CGRect(x: 0, y: 0, width: 1440, height: 600),
            "top half step 2 is vertical two thirds")
        expectRect(
            frame(.bottomHalf, step: 1, cycle: .sizes)!,
            CGRect(x: 0, y: 600, width: 1440, height: 300),
            "bottom half step 1 is a vertical third")
        expectRect(
            frame(.bottomHalf, step: 2, cycle: .sizes)!,
            CGRect(x: 0, y: 300, width: 1440, height: 600),
            "bottom half step 2 is vertical two thirds")

        // A step handed to a command that doesn't cycle must be ignored outright.
        for step in 0...5 {
            expectRect(
                frame(.firstThird, step: step, cycle: .sizes)!, frame(.firstThird)!,
                "non-cycling commands ignore step \(step)")
            expectRect(
                frame(.maximize, step: step, cycle: .sizes)!, frame(.maximize)!,
                "maximize ignores step \(step)")
            expectRect(
                frame(.leftHalf, step: step)!, frame(.leftHalf)!,
                "cycling switched off ignores step \(step)")
        }
        // Negative steps can't crash or escape the cycle.
        expectRect(
            frame(.leftHalf, step: -1, cycle: .sizes)!, frame(.firstTwoThirds)!,
            "negative steps normalize")
    }

    // MARK: - Non-divisible widths

    static func testNonDivisible() {
        // 1366 is the tie case for fourths: a quarter of it lands exactly on .5.
        for width in [1441, 1000, 1367, 1366] as [CGFloat] {
            let screen = WindowPlacementEngine.Screen(
                id: 9, frame: CGRect(x: 0, y: 0, width: width, height: 901),
                visibleFrame: CGRect(x: 0, y: 0, width: width, height: 901))
            let first = frame(.firstThird, on: screen)!
            let center = frame(.centerThird, on: screen)!
            let last = frame(.lastThird, on: screen)!
            expect(first.maxX == center.minX, "\(width): first/center thirds share an edge exactly")
            expect(center.maxX == last.minX, "\(width): center/last thirds share an edge exactly")
            expect(
                first.union(center).union(last) == screen.visibleFrame,
                "\(width): thirds still cover the whole screen")

            let left = frame(.leftHalf, on: screen)!
            let right = frame(.rightHalf, on: screen)!
            expect(left.maxX == right.minX, "\(width): halves share an edge exactly")
            expect(left.union(right) == screen.visibleFrame, "\(width): halves cover the screen")
            expect(abs(left.width - right.width) <= 1, "\(width): halves differ by at most a point")

            let top = frame(.topHalf, on: screen)!
            let bottom = frame(.bottomHalf, on: screen)!
            expect(top.maxY == bottom.minY, "\(width): vertical halves share an edge exactly")

            let firstFourths = frame(.firstThreeFourths, on: screen)!
            let lastFourths = frame(.lastThreeFourths, on: screen)!
            expect(
                abs(firstFourths.width - lastFourths.width) <= 1,
                "\(width): the two three-fourths differ by at most a point")
            expect(
                abs(firstFourths.width - width * 0.75) <= 1,
                "\(width): three fourths is three quarters of the screen")
            expect(
                firstFourths.union(lastFourths) == screen.visibleFrame,
                "\(width): the two three-fourths still cover the screen")
        }
    }

    // MARK: - Off-origin displays

    static func testOffOriginScreens() {
        // A display up and to the right of the primary — negative Y in AX space.
        let high = WindowPlacementEngine.Screen(
            id: 2, frame: CGRect(x: 1920, y: -300, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1920, y: -300, width: 2560, height: 1440))
        expectRect(
            frame(.leftHalf, on: high, window: CGRect(x: 2000, y: 0, width: 400, height: 300))!,
            CGRect(x: 1920, y: -300, width: 1280, height: 1440), "left half on an off-origin display")
        expect(
            frame(.topHalf, on: high, window: CGRect(x: 2000, y: 0, width: 400, height: 300))!.minY
                == -300, "top half honours a negative minY")

        // A display left of and below the primary.
        let low = WindowPlacementEngine.Screen(
            id: 3, frame: CGRect(x: -1440, y: 200, width: 1440, height: 900),
            visibleFrame: CGRect(x: -1440, y: 200, width: 1440, height: 900))
        expectRect(
            frame(.rightHalf, on: low, window: CGRect(x: -1000, y: 300, width: 400, height: 300))!,
            CGRect(x: -720, y: 200, width: 720, height: 900), "right half on a negative-X display")
        expectRect(
            frame(.maximize, on: low, window: CGRect(x: -1000, y: 300, width: 400, height: 300))!,
            low.visibleFrame, "maximize on a negative-X display")

        // A visible frame smaller than the full frame (menu bar and Dock reserved).
        let reserved = WindowPlacementEngine.Screen(
            id: 4, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800))
        expectRect(
            frame(.topHalf, on: reserved)!, CGRect(x: 0, y: 25, width: 1440, height: 400),
            "tiles respect a reserved visible frame")
        expectRect(
            frame(.maximize, on: reserved)!, reserved.visibleFrame, "maximize never covers the menu bar")
    }

    // MARK: - Gaps

    static func testGaps() {
        expectRect(
            frame(.leftHalf, gap: 10)!, CGRect(x: 10, y: 10, width: 705, height: 880),
            "left half with a 10pt gap")
        expectRect(
            frame(.rightHalf, gap: 10)!, CGRect(x: 725, y: 10, width: 705, height: 880),
            "right half with a 10pt gap")
        expect(
            frame(.leftHalf, gap: 10)!.maxX + 10 == frame(.rightHalf, gap: 10)!.minX,
            "the gutter between halves is exactly the gap")
        expect(
            frame(.topHalf, gap: 10)!.maxY + 10 == frame(.bottomHalf, gap: 10)!.minY,
            "the gutter between vertical halves is exactly the gap")

        // Every outer edge is inset by the full gap, every gutter is exactly one gap.
        let quarters = [
            frame(.topLeftQuarter, gap: 10)!, frame(.topRightQuarter, gap: 10)!,
            frame(.bottomLeftQuarter, gap: 10)!, frame(.bottomRightQuarter, gap: 10)!
        ]
        expect(quarters[0].maxX + 10 == quarters[1].minX, "quarters: vertical gutter is the gap")
        expect(quarters[0].maxY + 10 == quarters[2].minY, "quarters: horizontal gutter is the gap")
        expect(
            quarters.allSatisfy {
                $0.minX >= 10 && $0.minY >= 10 && $0.maxX <= 1430 && $0.maxY <= 890
            }, "quarters stay inset from every screen edge")

        // Fourths: the outer edge takes the full gap, the interior one half of it.
        expectRect(
            frame(.firstThreeFourths, gap: 10)!, CGRect(x: 10, y: 10, width: 1065, height: 880),
            "first three fourths with a 10pt gap")
        expectRect(
            frame(.lastThreeFourths, gap: 10)!, CGRect(x: 365, y: 10, width: 1065, height: 880),
            "last three fourths with a 10pt gap")

        // Thirds: two gutters, both exact.
        expect(
            frame(.firstThird, gap: 10)!.maxX + 10 == frame(.centerThird, gap: 10)!.minX,
            "thirds: first/center gutter is the gap")
        expect(
            frame(.centerThird, gap: 10)!.maxX + 10 == frame(.lastThird, gap: 10)!.minX,
            "thirds: center/last gutter is the gap")

        // An odd gap must not drift when halved and rounded.
        expect(
            frame(.leftHalf, gap: 9)!.maxX + 9 == frame(.rightHalf, gap: 9)!.minX,
            "an odd gap still produces an exact gutter")

        expectRect(
            frame(.maximize, gap: 12)!, CGRect(x: 12, y: 12, width: 1416, height: 876),
            "maximize honours the gap")

        // Degenerate gaps must never produce an unusable window.
        for gap in [-5, 0, 10_000] as [CGFloat] {
            let rect = frame(.leftHalf, gap: gap)!
            expect(rect.width > 0 && rect.height > 0, "gap \(gap) still yields a positive tile")
            expect(
                mainScreen.visibleFrame.contains(rect), "gap \(gap) keeps the tile on screen")
        }
        expectRect(frame(.leftHalf, gap: -5)!, frame(.leftHalf)!, "a negative gap reads as zero")
        // Every non-finite value reads as zero, so NaN and infinity behave alike.
        expectRect(frame(.leftHalf, gap: .nan)!, frame(.leftHalf)!, "a NaN gap reads as zero")
        expectRect(
            frame(.leftHalf, gap: .infinity)!, frame(.leftHalf)!, "an infinite gap reads as zero")
        // A merely oversized (but finite) gap is capped rather than zeroed.
        expectRect(
            frame(.leftHalf, gap: 10_000)!, frame(.leftHalf, gap: 90)!,
            "an oversized finite gap is capped to a tenth of the smaller dimension")
    }

    // MARK: - Sizing

    static func testSizing() {
        expectRect(frame(.maximize)!, mainScreen.visibleFrame, "maximize fills the visible frame")

        let almost = frame(.almostMaximize)!
        expectRect(almost, CGRect(x: 72, y: 45, width: 1296, height: 810), "almost maximize")
        expectRect(
            frame(.almostMaximize, window: almost)!, almost, "almost maximize is idempotent")
        expect(
            almost.midX == mainScreen.visibleFrame.midX
                && almost.midY == mainScreen.visibleFrame.midY,
            "almost maximize stays centred")

        let reasonable = frame(.reasonableSize)!
        expectRect(
            reasonable, CGRect(x: 288, y: 180, width: 864, height: 540), "reasonable size is 60%")
        expectRect(
            frame(.reasonableSize, window: reasonable)!, reasonable, "reasonable size is idempotent")

        // Small displays never reach the cap, so the fraction is what shows.
        let small = WindowPlacementEngine.Screen(
            id: 7, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 800))
        expectRect(
            frame(.reasonableSize, on: small)!, CGRect(x: 256, y: 160, width: 768, height: 480),
            "reasonable size is uncapped on a small display")

        // Large ones do, which is what keeps the command display-independent.
        let large = WindowPlacementEngine.Screen(
            id: 8, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
            visibleFrame: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let capped = frame(.reasonableSize, on: large)!
        expect(
            capped.width == 1025 && capped.height == 900, "reasonable size caps at 1025×900")
        expect(large.visibleFrame.contains(capped), "a capped reasonable size stays on screen")
        expect(
            abs(capped.midX - large.visibleFrame.midX) <= 0.5
                && abs(capped.midY - large.visibleFrame.midY) <= 0.5,
            "a capped reasonable size stays centred")

        let window = CGRect(x: 100, y: 200, width: 300, height: 400)
        let tall = frame(.maximizeHeight, window: window)!
        expect(
            tall.minX == 100 && tall.width == 300, "maximize height preserves minX and width exactly")
        expect(tall.minY == 0 && tall.height == 900, "maximize height fills the canvas vertically")

        let wide = frame(.maximizeWidth, window: window)!
        expect(
            wide.minY == 200 && wide.height == 400, "maximize width preserves minY and height exactly")
        expect(wide.minX == 0 && wide.width == 1440, "maximize width fills the canvas horizontally")

        // An off-screen window must not come back full-height and still off-screen.
        let stray = CGRect(x: -900, y: -900, width: 200, height: 150)
        let strayTall = frame(.maximizeHeight, window: stray)!
        expect(strayTall.minX == 0 && strayTall.width == 200, "maximize height clamps a stray x")
        expect(
            !strayTall.intersection(mainScreen.visibleFrame).isNull,
            "maximize height brings a stray window back on screen")
        let strayWide = frame(.maximizeWidth, window: stray)!
        expect(strayWide.minY == 0 && strayWide.height == 150, "maximize width clamps a stray y")
        expect(
            !strayWide.intersection(mainScreen.visibleFrame).isNull,
            "maximize width brings a stray window back on screen")

        expectRect(
            frame(.center, window: window)!, CGRect(x: 570, y: 250, width: 300, height: 400),
            "center preserves the size and centres it")
        expectRect(
            frame(.center, window: frame(.center, window: window)!)!,
            frame(.center, window: window)!, "center is idempotent")

        // A window larger than the screen must be clamped down, not centred off-screen.
        let huge = CGRect(x: -500, y: -500, width: 3000, height: 2000)
        let centred = frame(.center, window: huge)!
        expect(
            centred.width <= 1440 && centred.height <= 900, "center clamps an oversized window")
        expect(mainScreen.visibleFrame.contains(centred), "a clamped center stays on screen")

        expectRect(
            frame(.centerHalf)!, CGRect(x: 360, y: 0, width: 720, height: 900),
            "center half is half the screen's area")
        expectRect(
            frame(.centerTwoThirds)!, CGRect(x: 240, y: 0, width: 960, height: 900),
            "center two thirds is two thirds of the width, centred")
    }

    // MARK: - Make Larger / Make Smaller

    static func testLargerSmaller() {
        let start = CGRect(x: 100, y: 100, width: 600, height: 400)
        let larger = frame(.makeLarger, window: start)!
        expect(larger.width > start.width && larger.height > start.height, "make larger grows")
        // The assertion that justifies screen-relative steps: size-relative ones cannot round-trip.
        expectRect(
            frame(.makeSmaller, window: larger)!, start,
            "larger then smaller returns the exact original rect")
        let smaller = frame(.makeSmaller, window: start)!
        expectRect(
            frame(.makeLarger, window: smaller)!, start,
            "smaller then larger returns the exact original rect")
        expect(larger.midX == start.midX && larger.midY == start.midY, "growing keeps the centre")
        expect(smaller.midX == start.midX && smaller.midY == start.midY, "shrinking keeps the centre")

        // Repeated shrinking saturates at the floor instead of collapsing.
        var shrinking = start
        for _ in 0..<40 { shrinking = frame(.makeSmaller, window: shrinking)! }
        expect(shrinking.width > 0 && shrinking.height > 0, "40 shrinks never collapse the window")
        expectRect(
            frame(.makeSmaller, window: shrinking)!, shrinking, "shrinking saturates into a no-op")

        // Repeated growing converges on the canvas.
        var growing = start
        for _ in 0..<40 { growing = frame(.makeLarger, window: growing)! }
        expectRect(growing, mainScreen.visibleFrame, "40 grows converge on the maximized frame")
        expectRect(frame(.makeLarger, window: growing)!, growing, "growing saturates into a no-op")

        // With a gap, growing converges on the gapped canvas rather than the raw visible frame.
        var gapped = start
        for _ in 0..<40 { gapped = frame(.makeLarger, window: gapped, gap: 12)! }
        expectRect(gapped, frame(.maximize, gap: 12)!, "growing respects the gap")
    }

    // MARK: - Nudges

    static func testNudges() {
        let start = CGRect(x: 300, y: 300, width: 600, height: 400)
        for command in [WindowCommand.ID.moveLeft, .moveRight, .moveUp, .moveDown] {
            let moved = frame(command, window: start)!
            expect(moved.size == start.size, "\(command.rawValue) leaves the size untouched")
        }
        expectRect(
            frame(.moveLeft, window: start)!, CGRect(x: 228, y: 300, width: 600, height: 400),
            "move left nudges by 5% of the screen width")
        expectRect(
            frame(.moveUp, window: start)!, CGRect(x: 300, y: 255, width: 600, height: 400),
            "move up nudges by 5% of the screen height")
        expectRect(
            frame(.moveRight, window: frame(.moveLeft, window: start)!)!, start,
            "left then right returns the original position")
        expectRect(
            frame(.moveDown, window: frame(.moveUp, window: start)!)!, start,
            "up then down returns the original position")

        var sliding = start
        for _ in 0..<30 { sliding = frame(.moveLeft, window: sliding)! }
        expect(sliding.minX == 0, "30 nudges left end flush against the canvas edge")
        expect(sliding.size == start.size, "nudging to the edge never resizes")
        expectRect(frame(.moveLeft, window: sliding)!, sliding, "a flush window nudges no further")

        // A window wider than the canvas pins its leading edge rather than sliding off.
        let overWide = CGRect(x: 100, y: 100, width: 2000, height: 400)
        let pinned = frame(.moveLeft, window: overWide)!
        expect(pinned.minX == 0, "an oversized window pins to the canvas edge")
        expect(pinned.size == overWide.size, "an oversized nudge never resizes")
    }
}
