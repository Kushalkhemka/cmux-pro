import Foundation

/// A durable terminal-to-zmx mapping; moving a terminal preserves this identity.
public struct RemoteZmxBinding: Codable, Hashable, Sendable {
    /// The remote host and socket namespace.
    public let endpoint: RemoteZmxEndpoint
    /// The full, unprefixed remote session name.
    public let session: String

    /// Creates a mapping to a printable zmx session name.
    /// - Parameters:
    ///   - endpoint: The validated remote endpoint.
    ///   - session: An existing or newly assigned session name.
    /// - Throws: ValidationError for an unsafe name.
    public init(endpoint: RemoteZmxEndpoint, session: String) throws {
        guard RemoteZmxEndpoint.isSafeValue(session), !session.contains("/"),
              session != ".", session != "..", session.utf8.count <= 200
        else { throw RemoteZmxEndpoint.ValidationError.invalidValue }
        self.endpoint = endpoint
        self.session = session
    }

    private enum CodingKeys: String, CodingKey { case endpoint, session }

    /// Decodes and validates a persisted terminal mapping.
    /// - Parameter decoder: The saved mapping decoder.
    /// - Throws: A decoding or validation error.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(RemoteZmxEndpoint.self, forKey: .endpoint),
                      session: c.decode(String.self, forKey: .session))
    }

    /// Builds a remote attach that never recreates a missing restored session.
    /// - Parameter create: Allow creation on the first attachment of a new terminal.
    /// - Parameter command: Optional command for a newly created session only.
    /// - Parameter workingDirectory: Optional remote directory for session creation.
    /// - Returns: A POSIX shell program intended for an SSH PTY.
    public func attachScript(create: Bool, command: String? = nil, workingDirectory: String? = nil) -> String {
        let q = RemoteZmxEndpoint.quote
        let check = """
        if ! \(q(endpoint.executable)) get \(q(session)) >/dev/null 2>&1; then
        names=$(\(q(endpoint.executable)) list --short) || exit $?;
        found=0;
        while IFS= read -r name; do
          if [ "$name" = \(q(session)) ]; then found=1; break; fi;
        done <<CMUX_ZMX_NAMES
        $names
        CMUX_ZMX_NAMES
        [ "$found" = 1 ] || exit 44;
        fi;
        """
        // A successful read-only label probe checks only this daemon. Older zmx
        // clients/daemons can fall back to discovery without creating a session.
        let directory = create ? workingDirectory.map { "cd -- \(q($0)) || exit $?; " } ?? "" : ""
        let argv = command.flatMap { create ? ["/bin/sh", "-lc", $0] : nil } ?? []
        let suffix = argv.isEmpty ? "" : " " + argv.map(q).joined(separator: " ")
        return endpoint.shellPreamble + (create ? "" : check + "\n") + directory +
            "exec \(q(endpoint.executable)) attach \(q(session))" + suffix
    }

    /// Wraps SSH in a reconnect loop, stopping on detach, session exit, and remote errors.
    /// - Parameters:
    ///   - sshArguments: SSH options preceding the destination, including ControlMaster options.
    ///   - sshExecutable: SSH executable; injectable for transport lifecycle tests.
    ///   - create: Create on the first connection only; reconnects require an existing session.
    ///   - command: Remote command for a new session, omitted on reconnect.
    ///   - workingDirectory: Remote directory for a new session, omitted on reconnect.
    ///   - reconnectMessage: Localized connection-loss message.
    ///   - missingMessage: Localized missing-session message.
    /// - Returns: A command for a native Ghostty PTY, with exponential retry delay
    ///   capped at 15 seconds plus subsecond staggering across terminals.
    public func startupCommand(sshArguments: [String], sshExecutable: String = "/usr/bin/ssh", create: Bool = false,
                               reconnectMessage: String, missingMessage: String,
                               command: String? = nil, workingDirectory: String? = nil) -> String {
        let q = RemoteZmxEndpoint.quote
        let prefix = ([sshExecutable] + sshArguments + ["-tt", "--", endpoint.destination])
            .map(q).joined(separator: " ")
        // SSH first parses the remote command in the account's login shell.
        // Keep that command on one line even for tcsh and multiline creation commands.
        func remoteCommand(_ program: String) -> String {
            let encoded = program.utf8.map { String(format: "\\%03o", $0) }.joined()
            let decoder = "exec /bin/sh -c \"$(printf '%b' \(q(encoded)))\""
            return "/bin/sh -c " + q(decoder)
        }
        let reconnect = prefix + " " + q(remoteCommand(attachScript(create: false)))
        let initial = prefix + " " + q(remoteCommand(attachScript(create: create, command: command, workingDirectory: workingDirectory)))
        let script = """
        delay=1;
        jitter=$(printf '%03d' "$((($$ * 137 % 997) + 1))");
        started=$(date +%s);
        \(initial)
        rc=$?;
        while [ "$rc" = 255 ]; do
          ended=$(date +%s);
          if [ "$((ended - started))" -ge 30 ]; then delay=1; fi;
          printf '\\n%s\\n' \(q(reconnectMessage));
          sleep "$delay.$jitter";
          started=$(date +%s);
          \(reconnect)
          rc=$?;
          delay=$((delay * 2));
          [ "$delay" -le 15 ] || delay=15;
        done;
        if [ "$rc" = 44 ]; then printf '\\n%s\\n' \(q(missingMessage)); fi;
        exit "$rc"
        """
        return "/bin/sh -c " + q(script)
    }
}
