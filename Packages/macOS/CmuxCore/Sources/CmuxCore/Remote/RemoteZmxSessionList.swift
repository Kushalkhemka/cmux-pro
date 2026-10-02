import Foundation

/// Parses zmx's newline-delimited `list --short` output without splitting names on spaces.
public struct RemoteZmxSessionList: Sendable {
    /// Ordered, validated, unique session bindings.
    public let bindings: [RemoteZmxBinding]

    /// Parses discovery output, rejecting malformed names rather than partially mapping a host.
    /// - Parameters:
    ///   - output: UTF-8 output from `zmx list --short`.
    ///   - endpoint: The endpoint that produced the output.
    /// - Throws: ValidationError for malformed session names or an excessive session count.
    public init(output: String, endpoint: RemoteZmxEndpoint) throws {
        var seen: Set<String> = []
        var bindings: [RemoteZmxBinding] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let name = String(line)
            if seen.insert(name).inserted {
                bindings.append(try RemoteZmxBinding(endpoint: endpoint, session: name))
            }
        }
        guard bindings.count <= 256 else { throw RemoteZmxEndpoint.ValidationError.invalidValue }
        self.bindings = bindings
    }
}
