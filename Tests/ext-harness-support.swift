// The tally and checks the extension harnesses report through.
import Foundation

@MainActor var passes = 0
@MainActor var failures = 0

@MainActor func check(_ label: String, _ condition: Bool, _ detail: String? = nil) {
    if condition {
        passes += 1
        print("PASS  \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)" + (detail.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""))
    }
}

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    check(message, condition())
}

@MainActor func finish() -> Never {
    print("\n\(passes) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
