import Foundation
import Testing
@testable import BharatStockCore

@Suite("Request budget")
struct RequestBudgetTests {
    private func makeBudget(root: borrowing TempRoot, limit: Int = 50) -> RequestBudget {
        RequestBudget(
            paths: root.paths,
            limit: limit,
            schedule: RefreshSchedule(.default)
        )
    }

    @Test("Consumption accumulates and persists across instances")
    func consumptionPersists() async throws {
        let root = TempRoot()
        let now = Instant.ist(2026, 9, 28, 10, 30)

        let first = makeBudget(root: root)
        try await first.consume(1, now: now)
        try await first.consume(4, now: now)
        #expect(await first.current(now: now).spent == 5)

        // A fresh actor reads the ledger back off disk — the widget and the app are separate
        // processes, so the count has to survive the boundary.
        let second = makeBudget(root: root)
        #expect(await second.current(now: now).spent == 5)
    }

    @Test("Exhaustion throws and does not record the refused request")
    func exhaustionThrows() async throws {
        let root = TempRoot()
        let now = Instant.ist(2026, 9, 28, 10, 30)
        let budget = makeBudget(root: root, limit: 3)

        try await budget.consume(3, now: now)
        await #expect(throws: BudgetError.exhausted(spent: 3, limit: 3)) {
            try await budget.consume(1, now: now)
        }
        #expect(await budget.current(now: now).spent == 3)
        #expect(await budget.canSpend(1, now: now) == false)
    }

    @Test("The window rolls at IST midnight, not UTC midnight")
    func rollsAtISTMidnight() async throws {
        let root = TempRoot()
        let budget = makeBudget(root: root)

        let lateEvening = Instant.ist(2026, 9, 28, 23, 45)
        try await budget.consume(10, now: lateEvening)
        #expect(await budget.current(now: lateEvening).spent == 10)

        // 01:30 IST on the 29th is still 20:00 UTC on the 28th, so a UTC-based window would keep
        // counting the previous day here. An IST-based one must have rolled.
        let afterISTMidnight = Instant.ist(2026, 9, 29, 1, 30)
        #expect(await budget.current(now: afterISTMidnight).spent == 0)

        // The roll is re-derived from the ledger rather than persisted eagerly, so a separate
        // process asking about a moment still inside the original window sees the original count.
        let fresh = makeBudget(root: root)
        #expect(await fresh.current(now: Instant.ist(2026, 9, 28, 23, 59)).spent == 10)
        #expect(await fresh.current(now: afterISTMidnight).spent == 0)
    }

    @Test("A cycle is refused if its worst case would breach the five-request reserve")
    func reserveIsHonoured() async throws {
        let root = TempRoot()
        let now = Instant.ist(2026, 9, 28, 10, 30)
        let budget = makeBudget(root: root, limit: 50)

        // 50 - 0 - 5 = 45 available for a cycle.
        try await budget.authoriseCycle(worstCaseCost: 45, now: now)
        await #expect(throws: BudgetError.self) {
            try await budget.authoriseCycle(worstCaseCost: 46, now: now)
        }

        try await budget.consume(40, now: now)
        // 50 - 40 - 5 = 5 left for a cycle.
        try await budget.authoriseCycle(worstCaseCost: 5, now: now)
        await #expect(throws: BudgetError.self) {
            try await budget.authoriseCycle(worstCaseCost: 6, now: now)
        }

        // The reserve is not a hard floor for single requests: a retry or manual refresh may
        // draw on it, which is the whole point of keeping it back.
        #expect(await budget.canSpend(5, now: now) == true)
    }

    @Test("A config change to maxRequestsPerDay applies without resetting the day's spend")
    func limitChangeKeepsSpend() async throws {
        let root = TempRoot()
        let now = Instant.ist(2026, 9, 28, 10, 30)

        try await makeBudget(root: root, limit: 50).consume(12, now: now)

        let relimited = makeBudget(root: root, limit: 20)
        let ledger = await relimited.current(now: now)
        #expect(ledger.spent == 12)
        #expect(ledger.limit == 20)
        #expect(ledger.remaining == 8)
    }

    @Test("A simulated day — two scheduled windows plus two manual refreshes — stays under 50")
    func simulatedDayStaysUnderCeiling() async throws {
        let root = TempRoot()
        let budget = makeBudget(root: root, limit: 50)

        // The default watchlist: 3 stocks (one batch request) and 2 funds (one each).
        let perRefresh = RequestCost.stockRequests(symbolCount: 3) + RequestCost.fundRequests(fundCount: 2)
        #expect(perRefresh == 3, "a batch endpoint is the whole reason the ceiling is comfortable")

        var spent = 0
        for moment in [
            Instant.ist(2026, 9, 28, 10, 30),   // scheduled window 1
            Instant.ist(2026, 9, 28, 13, 5),    // manual
            Instant.ist(2026, 9, 28, 21, 30),   // scheduled window 2
            Instant.ist(2026, 9, 28, 22, 15),   // manual
        ] {
            try await budget.authoriseCycle(worstCaseCost: perRefresh * RetryPolicy.maxAttempts, now: moment)
            for _ in 0..<perRefresh {
                try await budget.consume(1, now: moment)
                spent += 1
            }
        }

        // Plus one forced failure that burns its full retry ladder.
        for _ in 0..<RetryPolicy.maxAttempts {
            try await budget.consume(1, now: Instant.ist(2026, 9, 28, 21, 31))
            spent += 1
        }

        let ledger = await budget.current(now: Instant.ist(2026, 9, 28, 23, 0))
        #expect(ledger.spent == spent)
        #expect(ledger.spent == 15)
        #expect(ledger.spent < 50, "§10: a full day of operation must provably stay under 50")
    }

    @Test("Even a full 15-instrument watchlist fits two windows a day")
    func worstCaseWatchlistFits() async throws {
        let root = TempRoot()
        let budget = makeBudget(root: root, limit: 50)

        // 15 rows in the least favourable split for cost: all funds, one request each.
        let allFunds = RequestCost.stockRequests(symbolCount: 0) + RequestCost.fundRequests(fundCount: 15)
        #expect(allFunds == 15)

        for moment in [Instant.ist(2026, 9, 28, 10, 30), Instant.ist(2026, 9, 28, 21, 30)] {
            for _ in 0..<allFunds { try await budget.consume(1, now: moment) }
        }
        #expect(await budget.current(now: Instant.ist(2026, 9, 28, 22, 0)).spent == 30)
        // Still leaves room for a manual refresh and the reserve.
        try await budget.authoriseCycle(worstCaseCost: 15, now: Instant.ist(2026, 9, 28, 22, 0))
    }
}
