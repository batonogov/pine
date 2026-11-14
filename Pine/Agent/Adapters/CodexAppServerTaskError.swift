nonisolated enum CodexAppServerTaskError: Error, Equatable {
    case unavailable, alreadyBusy, notBound, staleRequest, invalidConfiguration
    case signInRequired, unsupportedProviderAccount, unsupportedSetupApproval, accountChanged
    case unsupportedApproval
}
