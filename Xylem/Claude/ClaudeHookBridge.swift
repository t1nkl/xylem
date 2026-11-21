//
//  ClaudeHookBridge.swift
//  Xylem
//
//  How Xylem learns what the claude in each tab is doing. Every claude a
//  tab starts gets `--settings ~/.xylem/hooks/settings.json`, which adds
//  command hooks for the session/turn events. The hook script writes the
//  event's JSON (Claude Code passes it on stdin) to
//  `~/.xylem/tab-events/<tab id>.json`, keyed by the `XYLEM_TAB_ID`
//  variable the tab's shell exports. Only the latest event is kept - the
//  state needs nothing older - and the write is atomic (temp file + mv),
//  so a reader never sees half a file.
//
//  Verified against Claude Code 2.1.323: hooks from `--settings` fire (also
//  with -p); every event carries `session_id` and `transcript_path`;
//  `/clear` sends SessionEnd(reason clear) then SessionStart(source clear)
//  with a new id; a permission prompt sends Notification(notification_type
//  permission_prompt); Esc sends nothing (see ClaudeTabState). A turn an
//  API error ended sends StopFailure instead of Stop, with `error`
//  (rate_limit, authentication_failed, server_error, unknown, …) and the
//  error text as `last_assistant_message` (2.1.329).
//
//  A UserPromptSubmit is also kept as `<tab id>.prompt` (its hook passes
//  the script a `prompt` argument): the event file keeps only the latest
//  event, so a prompt followed within a second by a tool call or a Stop
//  would never be seen. The marker's mtime and session tell whether the
//  human typed a new prompt in the tab's own session (an agent-team
//  teammate runs under the same tab id) since the last known Stop.
//
//  The same settings set Claude Code's status line to a second script: it
//  keeps the JSON Claude Code passes (model, effort, context; `effort.level`
//  is there in 2.1.200 to 2.1.329) as `<tab id>.status` for the toolbar,
//  then runs the user's own status line command, if any, with the same
//  input (kept per tab in `<tab id>.statusline`, owner-only, from their
//  settings), so their line still shows: a `statusLine` in `--settings`
//  replaces theirs. Its `padding` comes from the user's global status line,
//  read when the files are written (each launch): Claude Code drops leading
//  spaces from a status line's output, so the script can't indent it, and
//  the settings file is one for all tabs, so a project's own padding isn't
//  followed (2.1.329: padding 6 puts the text 6 columns further right than
//  none or 0). Claude Code runs a status line only in a trusted folder and
//  not with `disableAllHooks`, so the user's command runs exactly when
//  Claude Code itself would run it.
//
//  The script is silent and always exits 0: hook stdout can be fed back to
//  Claude, and a failing hook would show up in the user's session. Without
//  `XYLEM_TAB_ID` (a claude started by hand in some other terminal that
//  inherited nothing from us) it does nothing.
//

import Foundation

nonisolated enum ClaudeHookBridge {
    /// Events the bridge subscribes to. PreToolUse/PostToolUse mark the
    /// turn as running again after a permission answer.
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Stop", "Notification", "SessionEnd", stopFailureEvent
    ]

    /// Sent instead of Stop when an API error ended the turn (rate limit,
    /// authentication, server error). Claude Code before 2.1.78 doesn't know
    /// it, and an unknown event name makes those versions drop every hook in
    /// the file (2.1.77 and 2.0.50: not one event fired), so their tabs get
    /// `legacySettingsName`, the same file without it.
    static let stopFailureEvent = "StopFailure"
    static let stopFailureSince = "2.1.78"
    static let settingsName = "settings.json"
    static let legacySettingsName = "settings-legacy.json"

    static let environmentKey = "XYLEM_TAB_ID"

    static let statusExtension = "status"
    /// The user's own status line command for the tab's folder, run by the
    /// status line script after it has kept the input.
    static let userStatusLineExtension = "statusline"

    /// On the command line of every claude a Xylem tab starts (`--settings
    /// …/.xylem/hooks/settings.json` or `settings-legacy.json`): tells our
    /// processes from others.
    static let settingsFileMarker = "/.xylem/hooks/settings"

    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".xylem", directoryHint: .isDirectory)
    }

    static var eventsDirectory: URL {
        rootDirectory.appending(path: "tab-events", directoryHint: .isDirectory)
    }

    static func eventFile(forTab id: UUID, in directory: URL = eventsDirectory) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    /// Touched by every UserPromptSubmit of the tab (only its mtime counts).
    static func promptMarker(forTab id: UUID, in directory: URL = eventsDirectory) -> URL {
        directory.appending(path: "\(id.uuidString).\(promptMarkerExtension)")
    }

    static let promptMarkerExtension = "prompt"

    /// The tab's latest status line input.
    static func statusFile(forTab id: UUID, in directory: URL = eventsDirectory) -> URL {
        directory.appending(path: "\(id.uuidString).\(statusExtension)")
    }

    static func userStatusLineFile(forTab id: UUID, in directory: URL = eventsDirectory) -> URL {
        directory.appending(path: "\(id.uuidString).\(userStatusLineExtension)")
    }

    /// Keeps (or, with nil, removes) the user's status line command for the
    /// tab's script; owner-only like the events.
    static func setUserStatusLine(_ command: String?, forTab id: UUID, in directory: URL = eventsDirectory) {
        let url = userStatusLineFile(forTab: id, in: directory)
        guard let command, !command.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: Data(command.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The script argument UserPromptSubmit's hook passes.
    static let promptArgument = "prompt"

    /// The settings path from this launch's `install()`; nil = the files
    /// could not be written and tabs run without the bridge (Doctor says so).
    /// Written once per launch: the files only change with the app.
    static let installedSettingsPath: String? = install()

    /// The settings file for a claude of `version`: the one with StopFailure
    /// from 2.1.78, else (also when the version is unknown) the one without.
    static func settingsPath(installed: String?, claudeVersion version: String?) -> String? {
        guard let installed else { return nil }
        if let version, ClaudeCLIVersion.isVersion(version, atLeast: stopFailureSince) { return installed }
        return (installed as NSString).deletingLastPathComponent + "/" + legacySettingsName
    }

    /// Writes the hook script and settings file when their content differs
    /// (first launch, or a template change after an update) and returns the
    /// settings path for `--settings`; nil if they can't be written, in
    /// which case tabs simply run without the bridge.
    @discardableResult
    static func install(root: URL = rootDirectory,
                        userSettings: ClaudeSettingsReading = ClaudeSettingsReader()) -> String? {
        let hooksDir = root.appending(path: "hooks", directoryHint: .isDirectory)
        let eventsDir = root.appending(path: "tab-events", directoryHint: .isDirectory)
        let script = hooksDir.appending(path: "tab-event.sh")
        let statusScript = hooksDir.appending(path: "status-line.sh")
        let settings = hooksDir.appending(path: settingsName)
        let legacySettings = hooksDir.appending(path: legacySettingsName)
        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
            // Events hold prompts: owner-only, also for a folder made by
            // an older version with the default umask.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: eventsDir.path)
            try writeIfChanged(scriptSource(eventsDirectory: eventsDir.path), to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try writeIfChanged(statusScriptSource(eventsDirectory: eventsDir.path), to: statusScript)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusScript.path)
            let padding = userSettings.readGlobalSettings()?.statusLine?.padding
            try writeIfChanged(settingsSource(scriptPath: script.path, statusScriptPath: statusScript.path,
                                              statusLinePadding: padding), to: settings)
            try writeIfChanged(settingsSource(scriptPath: script.path, statusScriptPath: statusScript.path,
                                              statusLinePadding: padding, events: legacyEvents), to: legacySettings)
            return settings.path
        } catch {
            return nil
        }
    }

    static func scriptSource(eventsDirectory: String) -> String {
        """
        #!/bin/sh
        # Auto-generated by Xylem - rewritten on every launch, don't edit.
        # Claude Code runs this for each hook event of a claude started in a
        # Xylem tab; the tab's latest event tells Xylem what Claude is doing.
        # Owner-only: a UserPromptSubmit event carries the whole prompt.
        umask 077
        id="$\(environmentKey)"
        [ -n "$id" ] || exit 0
        case "$id" in *[!A-Za-z0-9-]*) exit 0 ;; esac
        dir=\(shellQuote(eventsDirectory))
        mkdir -p "$dir" 2>/dev/null
        tmp="$dir/.$id.$$"
        if cat > "$tmp" 2>/dev/null; then
            # The prompt's own copy (written first), so it outlives the event.
            [ "$1" = \(promptArgument) ] && cp "$tmp" "$tmp.p" 2>/dev/null && mv -f "$tmp.p" "$dir/$id.\(promptMarkerExtension)" 2>/dev/null
            mv -f "$tmp" "$dir/$id.json" 2>/dev/null
        fi
        rm -f "$tmp.p" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
        exit 0

        """
    }

    static func statusScriptSource(eventsDirectory: String) -> String {
        """
        #!/bin/sh
        # Auto-generated by Xylem - rewritten on every launch, don't edit.
        # Claude Code runs this to draw the status line of a claude started in
        # a Xylem tab. Its input (model, effort, context) is kept for the
        # tab's toolbar; then the user's own status line command, if any,
        # draws the line from the same input.
        input=$(cat)
        id="$\(environmentKey)"
        case "$id" in
            ''|*[!A-Za-z0-9-]*) ;;
            *) (
                umask 077
                dir=\(shellQuote(eventsDirectory))
                mkdir -p "$dir" 2>/dev/null
                tmp="$dir/.$id.\(statusExtension).$$"
                printf '%s' "$input" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$id.\(statusExtension)" 2>/dev/null
                rm -f "$tmp" 2>/dev/null
            ) ;;
        esac
        case "$id" in ''|*[!A-Za-z0-9-]*) exit 0 ;; esac
        user=\(shellQuote(eventsDirectory))"/$id.\(userStatusLineExtension)"
        [ -s "$user" ] || exit 0
        # Their command's exit status is the line's, as without Xylem.
        printf '%s' "$input" | /bin/sh -c "$(cat "$user")"

        """
    }

    /// Every event but StopFailure, for Claude Code before 2.1.78.
    static var legacyEvents: [String] { events.filter { $0 != stopFailureEvent } }

    static func settingsSource(scriptPath: String, statusScriptPath: String, statusLinePadding: Int? = nil,
                               events: [String] = events) -> String {
        let command = "/bin/sh " + shellQuote(scriptPath)
        func hook(_ command: String) -> [String: Any] { ["hooks": [["type": "command", "command": command]]] }
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [hook(event == "UserPromptSubmit" ? command + " " + promptArgument : command)]
        }
        var statusLine: [String: Any] = ["type": "command", "command": "/bin/sh " + shellQuote(statusScriptPath)]
        if let statusLinePadding { statusLine["padding"] = statusLinePadding }
        let data = (try? JSONSerialization.data(
            withJSONObject: ["hooks": hooks, "statusLine": statusLine],
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The tab's latest event, or nil when there is none (yet) or it can't
    /// be parsed. `modified` is the file's mtime: when the event happened.
    static func latestEvent(forTab id: UUID, in directory: URL = eventsDirectory) -> ClaudeTabEvent? {
        let url = eventFile(forTab: id, in: directory)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return ClaudeTabEvent.parse(data, at: modified)
    }

    /// The newest human prompt under the tab: when, and in which session
    /// (nil for a marker without one, from a pre-release build).
    static func lastPrompt(forTab id: UUID, in directory: URL = eventsDirectory) -> (time: Date, sessionID: String?)? {
        let url = promptMarker(forTab: id, in: directory)
        guard let time = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        let object = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return (time, (object?["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The tab's latest status line input and when it was written; nil
    /// without one.
    static func latestStatus(forTab id: UUID, in directory: URL = eventsDirectory) -> ClaudeLiveStatus? {
        let url = statusFile(forTab: id, in: directory)
        guard let time = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              let data = SafeFileRead.data(url, limit: 256 * 1024)
        else { return nil }
        return ClaudeLiveStatus.parse(data, at: time)
    }

    static func statusModificationDate(forTab id: UUID, in directory: URL = eventsDirectory) -> Date? {
        (try? statusFile(forTab: id, in: directory).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    static func modificationDate(forTab id: UUID, in directory: URL = eventsDirectory) -> Date? {
        (try? eventFile(forTab: id, in: directory).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// A closed tab's event file is never read again.
    static func removeEvents(forTab id: UUID, in directory: URL = eventsDirectory) {
        try? FileManager.default.removeItem(at: eventFile(forTab: id, in: directory))
        try? FileManager.default.removeItem(at: promptMarker(forTab: id, in: directory))
        try? FileManager.default.removeItem(at: statusFile(forTab: id, in: directory))
        try? FileManager.default.removeItem(at: userStatusLineFile(forTab: id, in: directory))
    }

    /// Drops event files of tabs that no longer exist. Closing a tab
    /// deletes its file, but the dying claude's SessionEnd hook can write it
    /// again right after; files untouched for `minimumAge` are safe to go.
    static func pruneEvents(keeping live: Set<UUID>, in directory: URL = eventsDirectory,
                            now: Date = Date(), minimumAge: TimeInterval = 30) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let extensions: Set<String> = ["json", promptMarkerExtension, statusExtension, userStatusLineExtension]
        for file in files where extensions.contains(file.pathExtension) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !live.contains(id),
                  let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) >= minimumAge
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func writeIfChanged(_ content: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What a tab's claude runs with, from its status line input: current at
/// once, also before the first reply and right after `/effort` or `/model`.
/// Any field may be missing (older Claude Code).
nonisolated struct ClaudeLiveStatus: Equatable, Sendable {
    /// Effort level (`effort.level`).
    var level: String? = nil
    /// Full model id (`model.id`, "claude-opus-5-5").
    var modelID: String? = nil
    /// Claude Code's version ("2.1.329").
    var version: String? = nil
    var sessionID: String? = nil
    /// The context window as Claude Code counts it (`context_window`); nil
    /// when the input has none.
    var context: Context? = nil
    /// The plan's usage limits (`rate_limits`); nil when the input has none
    /// (API keys, before the first request).
    var rateLimits: RateLimits? = nil
    /// When Claude Code passed it.
    var at: Date

    nonisolated struct Context: Equatable, Sendable {
        /// `used_percentage`: nil until the first reply of the session, and
        /// again after `/compact` until the next reply (2.1.329).
        var usedPercentage: Double?
        /// Input tokens of the latest request (`total_input_tokens`).
        var usedTokens: Int?
        /// `context_window_size`.
        var size: Int?
    }

    nonisolated struct RateLimits: Equatable, Sendable {
        var fiveHour: Window?
        var sevenDay: Window?
        /// Behind a Claude gateway: the fullest spend limit (`spend_limit`).
        var spend: Spend? = nil

        nonisolated struct Window: Equatable, Sendable {
            var usedPercentage: Double
            var resetsAt: Date?
        }

        /// A gateway spend limit: the percent used (above 100 once exceeded)
        /// and, from a gateway that reports them, the dollars and the
        /// period (daily, weekly, monthly).
        nonisolated struct Spend: Equatable, Sendable {
            var usedPercentage: Double
            var resetsAt: Date?
            var usedUSD: Double? = nil
            var limitUSD: Double? = nil
            var period: String? = nil
        }

        var isEmpty: Bool { fiveHour == nil && sevenDay == nil && spend == nil }
    }

    static func parse(_ data: Data, at time: Date) -> ClaudeLiveStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let status = ClaudeLiveStatus(
            level: text((object["effort"] as? [String: Any])?["level"]),
            modelID: text((object["model"] as? [String: Any])?["id"]),
            version: text(object["version"]),
            sessionID: text(object["session_id"]),
            context: (object["context_window"] as? [String: Any]).map(Self.context),
            rateLimits: (object["rate_limits"] as? [String: Any]).map(Self.rateLimits).flatMap { $0.isEmpty ? nil : $0 },
            at: time
        )
        return status.level == nil && status.modelID == nil && status.version == nil ? nil : status
    }

    /// A JSON number (`NSNumber`, not a Bool); `null` and anything else is nil.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func context(_ object: [String: Any]) -> Context {
        Context(usedPercentage: number(object["used_percentage"]),
                usedTokens: number(object["total_input_tokens"]).map { Int($0) },
                size: number(object["context_window_size"]).flatMap { $0 > 0 ? Int($0) : nil })
    }

    private static func rateLimits(_ object: [String: Any]) -> RateLimits {
        func window(_ value: Any?) -> RateLimits.Window? {
            guard let window = value as? [String: Any], let used = number(window["used_percentage"]) else { return nil }
            // Unix seconds.
            let resets = number(window["resets_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return RateLimits.Window(usedPercentage: used, resetsAt: resets)
        }
        var spend: RateLimits.Spend?
        if let raw = object["spend_limit"] as? [String: Any], let used = number(raw["used_percentage"]) {
            spend = RateLimits.Spend(
                usedPercentage: used,
                resetsAt: number(raw["resets_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                usedUSD: number(raw["used_usd"]).flatMap { $0 >= 0 ? $0 : nil },
                limitUSD: number(raw["limit_usd"]).flatMap { $0 > 0 ? $0 : nil },
                period: (raw["period"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return RateLimits(fiveHour: window(object["five_hour"]), sevenDay: window(object["seven_day"]), spend: spend)
    }
}
