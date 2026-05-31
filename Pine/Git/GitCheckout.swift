//
//  GitCheckout.swift
//  Pine
//
//  Branch checkout operations extracted from GitStatusProvider.
//

import Foundation

// MARK: - GitStatusProvider + Checkout

extension GitStatusProvider {

    /// Synchronously switches to the given branch and refreshes git status.
    func checkoutBranch(_ branch: String) -> (success: Bool, error: String) {
        guard let url = repositoryURL else { return (false, "No repository") }
        let result = GitCommand.run(["switch", branch], at: url)
        if result.exitCode == 0 {
            refresh()
            return (true, "")
        }
        return (false, result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Asynchronously switches to the given branch on a background thread,
    /// then refreshes status asynchronously. Safe to call from the main thread.
    func checkoutBranchAsync(_ branch: String) async -> (success: Bool, error: String) {
        guard let url = repositoryURL else { return (false, "No repository") }
        let progressID = progressTracker?.beginOperation(Strings.progressGitCheckout)

        // nonisolated-check:ignore -- closure body only calls nonisolated static helpers; tracked in #720
        let result = await runOnBackground {
            GitCommand.run(["switch", branch], at: url)
        }

        guard result.exitCode == 0 else {
            if let progressID { self.progressTracker?.endOperation(progressID) }
            return (false, result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let progressID { self.progressTracker?.endOperation(progressID) }
        await refreshAsync()
        return (true, "")
    }
}
