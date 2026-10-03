// The tally and checks every window-management harness reports through.
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

@MainActor func expectRect(_ actual: CGRect?, _ expected: CGRect, _ message: String) {
    if actual == expected {
        Tally.passes += 1
    } else {
        Tally.failures += 1
        let got = actual.map(String.init(describing:)) ?? "nil"
        print("FAIL: \(message) — got \(got), expected \(expected)")
    }
}

@MainActor func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual == expected {
        Tally.passes += 1
    } else {
        Tally.failures += 1
        print("FAIL: \(message) — got \(actual), expected \(expected)")
    }
}

@MainActor func expectThrows<E: Error & Equatable>(
    _ expected: E, _ message: String, _ body: () throws -> Void
) {
    do {
        try body()
        expect(false, message)
    } catch let error as E {
        expect(error == expected, message)
    } catch {
        expect(false, message)
    }
}
