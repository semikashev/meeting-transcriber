#if !APPSTORE

    import Foundation

    /// A run the Claude API turned away at the door: the account's usage limit
    /// (429) or a network it does not serve (403).
    ///
    /// Both are worth telling apart from any other failed run, because both
    /// pass by themselves and cost nothing to try again.
    extension ClaudeCLIProtocolGenerator {
        /// Caps how long the CLI itself waits out a capacity refusal.
        ///
        /// A user whose Claude Code settings carry
        /// `CLAUDE_CODE_RETRY_WATCHDOG` has their CLI wait until the usage
        /// limit resets, up to five hours. A protocol run inherited that,
        /// sat silent until its own ten-minute limit and was then stopped as
        /// a timeout, so every meeting that ended while the limit was reached
        /// lost its notes. The queue waited with it. Measured with CLI 2.1.331
        /// against a stub API answering 429: without the settings variable a
        /// run ends after 3 s; with it in `settings.json` the run waits on,
        /// also with `CLAUDE_CODE_RETRY_WATCHDOG=0` in its own environment;
        /// with this variable in its environment it ends at the cap. A CLI
        /// that does not know the variable (before 2.1.295) ignores it.
        ///
        /// It does not bound an unreachable API: with the connection refused
        /// the same CLI retried past 90 s, so that still ends at `timeout`.
        static let retryWaitLimitVariable = "CLAUDE_CODE_RETRY_WATCHDOG_MAX_WAIT_MS"

        /// A minute: room for a passing overload, too short to hold the queue.
        static let retryWaitLimitMilliseconds = "60000"

        /// The error for a refusal by the API's own status, nil for any other.
        /// The status, not the text: the sentences have changed between CLI
        /// versions ("Request not allowed", "Request blocked before it reached
        /// Anthropic's API").
        static func refusalError(status: Int?, message: String) -> ProtocolError? {
            switch status {
            case 429: .cliUsageLimit(message)
            case 403: .cliBlocked(message)
            default: nil
            }
        }
    }

#endif
