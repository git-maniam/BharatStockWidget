import Foundation
import Testing
@testable import BharatStockCore

@Suite("Refresh schedule and gate")
struct RefreshScheduleTests {
    let schedule = RefreshSchedule(.default)  // 10:30 and 21:30 IST

    @Test("Window boundaries are the same instants whatever the machine's zone is")
    func boundariesAreZoneIndependent() {
        // The spec's launchd design had to rewrite a plist on every time-zone change because
        // StartCalendarInterval fires in local time. Anchoring the schedule to IST removes the
        // problem outright: these are absolute instants, so a machine in Cupertino, London or
        // Mumbai computes identical values.
        let day = Instant.ist(2026, 9, 28, 12, 0)
        let expected = [Instant.ist(2026, 9, 28, 10, 30), Instant.ist(2026, 9, 28, 21, 30)]

        #expect(schedule.boundaries(onDayOf: day) == expected)

        for identifier in ["America/Los_Angeles", "UTC", "Asia/Kolkata", "Pacific/Auckland"] {
            let zone = TimeZone(identifier: identifier)!
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            // Same instant, expressed from a different zone's point of view.
            #expect(schedule.boundaries(onDayOf: day) == expected, "differs under \(identifier)")
            _ = calendar
        }
    }

    @Test("The most recent boundary looks back across the day boundary")
    func mostRecentBoundary() {
        // Just before the first window: the answer is last night's 21:30.
        #expect(
            schedule.mostRecentBoundary(at: Instant.ist(2026, 9, 28, 9, 0))
                == Instant.ist(2026, 9, 27, 21, 30)
        )
        // Between the windows.
        #expect(
            schedule.mostRecentBoundary(at: Instant.ist(2026, 9, 28, 15, 0))
                == Instant.ist(2026, 9, 28, 10, 30)
        )
        // Exactly on a boundary counts as having elapsed.
        #expect(
            schedule.mostRecentBoundary(at: Instant.ist(2026, 9, 28, 21, 30))
                == Instant.ist(2026, 9, 28, 21, 30)
        )
    }

    @Test("The next boundary rolls into tomorrow after the last window")
    func nextBoundary() {
        #expect(
            schedule.nextBoundary(after: Instant.ist(2026, 9, 28, 9, 0))
                == Instant.ist(2026, 9, 28, 10, 30)
        )
        #expect(
            schedule.nextBoundary(after: Instant.ist(2026, 9, 28, 22, 0))
                == Instant.ist(2026, 9, 29, 10, 30)
        )
        // On the boundary, the *next* one is strictly later.
        #expect(
            schedule.nextBoundary(after: Instant.ist(2026, 9, 28, 10, 30))
                == Instant.ist(2026, 9, 28, 21, 30)
        )
    }

    @Test("A US DST transition does not move an IST window")
    func usDSTTransitionIsIrrelevant() {
        // US Pacific leaves DST on 1 Nov 2026. A launchd plist expressed in local time would need
        // rewriting across this date; an IST-anchored instant does not move at all.
        let before = schedule.boundaries(onDayOf: Instant.ist(2026, 10, 31, 12, 0))
        let after = schedule.boundaries(onDayOf: Instant.ist(2026, 11, 2, 12, 0))

        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        #expect(pacific.secondsFromGMT(for: before[0]) != pacific.secondsFromGMT(for: after[0]),
                "the fixture dates must actually straddle the transition")

        // Each boundary is still exactly 10:30 / 21:30 in IST.
        var istCalendar = Calendar(identifier: .gregorian)
        istCalendar.timeZone = DayTime.indiaStandardTime
        for boundaries in [before, after] {
            #expect(istCalendar.component(.hour, from: boundaries[0]) == 10)
            #expect(istCalendar.component(.minute, from: boundaries[0]) == 30)
            #expect(istCalendar.component(.hour, from: boundaries[1]) == 21)
            #expect(istCalendar.component(.minute, from: boundaries[1]) == 30)
        }
    }

    @Test("IST midnight is the budget window boundary")
    func marketMidnight() {
        #expect(
            schedule.mostRecentMarketMidnight(at: Instant.ist(2026, 9, 28, 23, 59))
                == Instant.ist(2026, 9, 28, 0, 0)
        )
        #expect(
            schedule.mostRecentMarketMidnight(at: Instant.ist(2026, 9, 29, 0, 1))
                == Instant.ist(2026, 9, 29, 0, 0)
        )
    }

    @Test("An empty schedule never reports a boundary rather than crashing")
    func emptySchedule() {
        let empty = RefreshSchedule(times: [], timeZone: DayTime.indiaStandardTime)
        #expect(empty.mostRecentBoundary(at: .now) == nil)
        #expect(empty.nextBoundary(after: .now) == nil)
    }

    // MARK: - The gate

    @Test("A window is served once, however often the extension is woken")
    func windowServedOnce() async throws {
        let root = TempRoot()
        let gate = RefreshGate(paths: root.paths)

        let atWindow = Instant.ist(2026, 9, 28, 10, 31)
        let decision = await gate.decideScheduled(schedule: schedule, now: atWindow)
        #expect(decision == .fetch(window: Instant.ist(2026, 9, 28, 10, 30)))

        try await gate.recordSuccess(window: decision.creditedWindow, isManual: false, now: atWindow)

        // WidgetKit may wake the extension many more times before the next window; none of those
        // may spend a request.
        for minute in [32, 45, 59] {
            let again = await gate.decideScheduled(
                schedule: schedule, now: Instant.ist(2026, 9, 28, 12, minute)
            )
            #expect(again == .alreadyServed(window: Instant.ist(2026, 9, 28, 10, 30)))
            #expect(!again.shouldFetch)
        }

        // The evening window is a different boundary, so it is eligible again.
        let evening = await gate.decideScheduled(
            schedule: schedule, now: Instant.ist(2026, 9, 28, 21, 30)
        )
        #expect(evening == .fetch(window: Instant.ist(2026, 9, 28, 21, 30)))
    }

    @Test("A late wake-up still credits the window it belongs to")
    func lateFetchCreditsTheWindow() async throws {
        let root = TempRoot()
        let gate = RefreshGate(paths: root.paths)

        // The Mac was asleep at 10:30 and only woke at 14:00 — a fetch is due, and it counts as
        // the 10:30 window rather than as an extra one.
        let decision = await gate.decideScheduled(
            schedule: schedule, now: Instant.ist(2026, 9, 28, 14, 0)
        )
        #expect(decision == .fetch(window: Instant.ist(2026, 9, 28, 10, 30)))
        try await gate.recordSuccess(window: decision.creditedWindow, isManual: false, now: Instant.ist(2026, 9, 28, 14, 0))

        #expect(
            await gate.decideScheduled(schedule: schedule, now: Instant.ist(2026, 9, 28, 14, 5))
                == .alreadyServed(window: Instant.ist(2026, 9, 28, 10, 30))
        )
    }

    @Test("Catch-up after a two-day sleep fetches exactly once")
    func catchUpAfterLongSleep() async throws {
        let root = TempRoot()
        let gate = RefreshGate(paths: root.paths)

        try await gate.recordSuccess(
            window: Instant.ist(2026, 9, 26, 21, 30), isManual: false,
            now: Instant.ist(2026, 9, 26, 21, 31)
        )

        // Woken two days later: one fetch, credited to the latest elapsed window — not one fetch
        // per window missed, which would be four requests spent on data that is now superseded.
        let wake = Instant.ist(2026, 9, 28, 16, 0)
        let decision = await gate.decideScheduled(schedule: schedule, now: wake)
        #expect(decision == .fetch(window: Instant.ist(2026, 9, 28, 10, 30)))

        try await gate.recordSuccess(window: decision.creditedWindow, isManual: false, now: wake)
        #expect(!(await gate.decideScheduled(schedule: schedule, now: wake)).shouldFetch)
    }

    @Test("Manual refresh is throttled to one per five minutes")
    func manualThrottle() async throws {
        let root = TempRoot()
        let gate = RefreshGate(paths: root.paths)
        let first = Instant.ist(2026, 9, 28, 13, 0)

        #expect(await gate.decideManual(now: first) == .fetch(window: nil))
        try await gate.recordSuccess(window: nil, isManual: true, now: first)

        #expect(
            await gate.decideManual(now: first.addingTimeInterval(60))
                == .manualThrottled(retryAt: first.addingTimeInterval(RefreshGate.manualCooldown))
        )
        #expect(await gate.decideManual(now: first.addingTimeInterval(301)) == .fetch(window: nil))
    }

    @Test("A manual refresh does not consume a scheduled window")
    func manualDoesNotConsumeWindow() async throws {
        let root = TempRoot()
        let gate = RefreshGate(paths: root.paths)

        // Manual refresh at 09:00, before the morning window.
        try await gate.recordSuccess(window: nil, isManual: true, now: Instant.ist(2026, 9, 28, 9, 0))

        // 10:30 must still be due; otherwise an early manual refresh would silently cancel the
        // day's first scheduled update.
        #expect(
            await gate.decideScheduled(schedule: schedule, now: Instant.ist(2026, 9, 28, 10, 30))
                == .fetch(window: Instant.ist(2026, 9, 28, 10, 30))
        )
    }
}
