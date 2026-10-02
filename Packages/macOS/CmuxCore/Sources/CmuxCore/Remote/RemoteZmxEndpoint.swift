import Foundation

/// An SSH endpoint and zmx socket namespace, independent of cmux's local layout.
public struct RemoteZmxEndpoint: Codable, Hashable, Sendable {
    /// SSH alias or user@host destination.
    public let destination: String
    /// Explicit SSH port, or nil to use ssh_config.
    public let port: Int?
    /// SSH identity file, or nil to use ssh_config.
    public let identityFile: String?
    /// Remote executable name or absolute path.
    public let executable: String
    /// Explicit remote ZMX_DIR, or nil to use zmx's default namespace.
    public let socketDirectory: String?

    /// Invalid endpoint or session metadata.
    public enum ValidationError: Error { case invalidValue }

    /// Creates a validated endpoint without performing I/O.
    /// - Parameters:
    ///   - destination: SSH alias or user@host; options and hidden characters are rejected.
    ///   - port: Explicit port in 1...65535.
    ///   - identityFile: Optional key path.
    ///   - executable: Remote zmx executable; defaults to zmx on PATH.
    ///   - socketDirectory: Optional absolute remote socket directory.
    /// - Throws: ValidationError for invalid metadata.
    public init(destination: String, port: Int? = nil, identityFile: String? = nil,
                executable: String = "zmx", socketDirectory: String? = nil) throws {
        guard Self.isSafeValue(destination), !destination.contains(where: { $0.isWhitespace }),
              port.map({ (1...65535).contains($0) }) ?? true,
              identityFile.map(Self.isSafeValue) ?? true,
              Self.isSafeValue(executable),
              executable == "zmx" || executable.hasPrefix("/"),
              socketDirectory.map({ Self.isSafeValue($0) && $0.hasPrefix("/") }) ?? true
        else { throw ValidationError.invalidValue }
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.executable = executable
        self.socketDirectory = socketDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case destination, port, identityFile, executable, socketDirectory
    }

    /// Decodes through the same validation boundary used for socket requests.
    /// - Parameter decoder: The saved endpoint decoder.
    /// - Throws: A decoding or validation error.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(destination: c.decode(String.self, forKey: .destination),
                      port: c.decodeIfPresent(Int.self, forKey: .port),
                      identityFile: c.decodeIfPresent(String.self, forKey: .identityFile),
                      executable: c.decodeIfPresent(String.self, forKey: .executable) ?? "zmx",
                      socketDirectory: c.decodeIfPresent(String.self, forKey: .socketDirectory))
    }

    /// True for a single printable non-option argument.
    /// - Parameter value: The metadata to validate.
    /// - Returns: Whether it can be passed as a literal argument.
    public static func isSafeValue(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.utf8.count <= 4096 &&
        !value.unicodeScalars.contains {
            [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
    }

    /// Quotes a literal POSIX shell argument.
    /// - Parameter value: The literal argument.
    /// - Returns: A single shell word that cannot expand or execute its contents.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A remote shell preamble shared by discovery and PTY attachment.
    public var shellPreamble: String {
        "unset ZMX_SESSION ZMX_SESSION_PREFIX; export PATH=\"$HOME/.local/bin:$PATH\"; " +
        (socketDirectory.map { "export ZMX_DIR=\(Self.quote($0)); " } ?? "")
    }

    /// Lists complete names in the configured namespace without a remote PTY.
    public var discoveryScript: String {
        shellPreamble + Self.quote(executable) + " list --short"
    }

    /// Dedicated terminal connections avoid shared SSH session limits and traffic contention.
    /// Discovery can still use a short-lived shared master independently.
    public var terminalSSHArguments: [String] {
        var arguments = ["-o", "RemoteCommand=none", "-o", "ControlMaster=no",
            "-o", "ControlPath=none", "-o", "ControlPersist=no",
            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=3"]
        if let port { arguments += ["-p", String(port)] }
        if let identityFile { arguments += ["-i", identityFile] }
        return arguments
    }
}
