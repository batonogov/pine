//
//  TestChildStartupPolicy.swift
//  Pine
//

#if PINE_TEST_HOST
/// Controlled startup for private test-host terminal children (#1792).
///
/// Compiled only into the private PINE_TEST_HOST/Testing app build; the
/// ordinary Debug/Release binaries never contain it, so production shell
/// selection, argv, and user preferences are untouched.
nonisolated enum TestChildStartupPolicy {
    /// Trusted non-login, no-startup shell for the default test terminal.
    static let executablePath = "/bin/bash"
    static let arguments = ["--noprofile", "--norc", "--noediting", "-i"]

    /// Removes only test-child startup/history/prompt injection variables
    /// from an inherited environment. `HOME`, `PATH`, and every other
    /// value pass through unchanged.
    static func environment(from inherited: [String: String]) -> [String: String] {
        var environment = inherited
        for key in environment.keys where startupKeys.contains(key)
            || key.hasPrefix("BASH_FUNC_") {
            environment.removeValue(forKey: key)
        }
        environment["HISTFILE"] = "/dev/null"
        environment["HISTSIZE"] = "0"
        environment["HISTFILESIZE"] = "0"
        environment["PS1"] = ""
        environment["PS2"] = ""
        environment["PS4"] = ""
        return environment
    }

    private static let startupKeys: Set<String> = [
        "BASH_ENV", "ENV", "ZDOTDIR", "INPUTRC", "PROMPT_COMMAND",
        "PS0", "PS1", "PS2", "PS3", "PS4", "PROMPT", "RPROMPT",
        "SHELLOPTS", "BASHOPTS", "CDPATH", "GLOBIGNORE",
        "HISTFILE", "HISTSIZE", "HISTFILESIZE",
    ]
}
#endif
