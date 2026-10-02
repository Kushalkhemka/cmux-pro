import Foundation
import Testing
@testable import CmuxCore

struct RemoteZmxTests {
    @Test func validatesAndRoundTripsMappings() throws {
        let endpoint = try RemoteZmxEndpoint(destination: "dev@host", port: 2222,
            identityFile: "/tmp/key with spaces", executable: "/opt/zmx", socketDirectory: "/run/zmx")
        let binding = try RemoteZmxBinding(endpoint: endpoint, session: "project α's terminal")
        #expect(try JSONDecoder().decode(RemoteZmxBinding.self, from: JSONEncoder().encode(binding)) == binding)
        #expect(throws: (any Error).self) { try RemoteZmxEndpoint(destination: "-oProxyCommand=bad") }
        #expect(throws: (any Error).self) { try RemoteZmxEndpoint(destination: "host\nother") }
        #expect(throws: (any Error).self) { try RemoteZmxEndpoint(destination: "host", port: 0) }
        #expect(throws: (any Error).self) { try RemoteZmxBinding(endpoint: endpoint, session: "../other") }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RemoteZmxEndpoint.self, from: Data("{\"destination\":\"-bad\"}".utf8))
        }
    }

    @Test func discoveryKeepsFullNamesAndDeduplicates() throws {
        let endpoint = try RemoteZmxEndpoint(destination: "host")
        let list = try RemoteZmxSessionList(output: "agent one\nα\nagent one\n", endpoint: endpoint)
        #expect(list.bindings.map(\.session) == ["agent one", "α"])
        #expect(try RemoteZmxSessionList(output: "", endpoint: endpoint).bindings.isEmpty)
        #expect(throws: (any Error).self) { try RemoteZmxSessionList(output: "good\nbad\tname\n", endpoint: endpoint) }
    }

    @Test func terminalTransportOverridesSharedMasterConfiguration() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("ssh_config")
        try "Host *\n  ControlMaster auto\n  ControlPath /tmp/shared-master\n  RemoteCommand unwanted-command\n".write(to: config, atomically: true, encoding: .utf8)
        let endpoint = try RemoteZmxEndpoint(destination: "example.test", port: 2222)
        let argv = ["/usr/bin/ssh", "-G", "-F", config.path] + endpoint.terminalSSHArguments + [endpoint.destination]
        let result = try run(argv.map(RemoteZmxEndpoint.quote).joined(separator: " "), in: dir)
        #expect(result.status == 0)
        let effective = result.output.split(separator: "\n").map(String.init)
        #expect(effective.contains("controlmaster false"))
        #expect(!effective.contains("controlpath /tmp/shared-master"))
        #expect(!effective.contains("remotecommand unwanted-command"))
        #expect(effective.contains("port 2222"))
    }

    @Test func attachPassesNamesLiterallyAndClearsNestedEnvironment() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "agent's $(touch sentinel)"
        let executable = dir.appendingPathComponent("zmx stub").path
        let q = RemoteZmxEndpoint.quote
        try writeExecutable("""
        #!/bin/sh
        if [ "$1" = list ]; then printf '%s\\n' \(q(name)); exit 0; fi
        printf '%s\\n%s\\n%s\\n' "$2" "${ZMX_SESSION-unset}" "${ZMX_SESSION_PREFIX-unset}"
        """, path: executable)
        let endpoint = try RemoteZmxEndpoint(destination: "host", executable: executable)
        let binding = try RemoteZmxBinding(endpoint: endpoint, session: name)
        let result = try run(binding.attachScript(create: false), in: dir,
            environment: ["ZMX_SESSION": "parent", "ZMX_SESSION_PREFIX": "prefix."])
        #expect(result.status == 0)
        #expect(result.output == name + "\nunset\nunset\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sentinel").path))
    }

    @Test func missingRestoreDoesNotCreateSession() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("zmx").path
        try writeExecutable("#!/bin/sh\n[ \"$1\" = list ] && exit 0\ntouch created\n", path: executable)
        let binding = try RemoteZmxBinding(endpoint: RemoteZmxEndpoint(destination: "host", executable: executable), session: "gone")
        #expect(try run(binding.attachScript(create: false), in: dir).status == 44)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("created").path))
        #expect(try run(binding.attachScript(create: true), in: dir).status == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("created").path))
    }

    @Test func creationCommandAndDirectoryApplyOnlyToNewSessions() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let remoteDirectory = dir.appendingPathComponent("project's directory")
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent("zmx").path
        try writeExecutable("""
        #!/bin/sh
        if [ "$1" = list ]; then printf 'agent\\n'; exit 0; fi
        pwd
        printf '%s\\n' "$@"
        """, path: executable)
        let binding = try RemoteZmxBinding(endpoint: RemoteZmxEndpoint(destination: "host", executable: executable), session: "agent")
        let command = "printf 'agent command'"
        let created = try run(binding.attachScript(create: true, command: command, workingDirectory: remoteDirectory.path), in: dir)
        #expect(created.status == 0)
        #expect(created.output == remoteDirectory.path + "\nattach\nagent\n/bin/sh\n-lc\n" + command + "\n")
        let restored = try run(binding.attachScript(create: false, command: command, workingDirectory: "/does-not-exist"), in: dir)
        #expect(restored.status == 0)
        let originalDirectory = try run("pwd", in: dir).output
        #expect(restored.output == originalDirectory + "attach\nagent\n")
    }

    @Test func reconnectsTransportFailureButStopsOnDetach() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ssh = dir.appendingPathComponent("ssh").path
        try writeExecutable("""
        #!/bin/sh
        if [ ! -f attempted ]; then touch attempted; exit 255; fi
        printf 'attached\\n'
        exit 0
        """, path: ssh)
        let binding = try RemoteZmxBinding(endpoint: RemoteZmxEndpoint(destination: "host"), session: "agent")
        let command = binding.startupCommand(sshArguments: [], sshExecutable: ssh,
            reconnectMessage: "retry", missingMessage: "missing")
        let result = try run(command, in: dir)
        #expect(result.status == 0)
        #expect(result.output.contains("retry"))
        #expect(result.output.hasSuffix("attached\n"))
        // A deliberate detach is success and must not enter the reconnect loop.
        let detached = try run(command, in: dir)
        #expect(detached.output == "attached\n")
    }

    @Test(arguments: [false, true])
    func attachmentWorksThroughNonPOSIXLoginShell(create: Bool) throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("zmx").path
        try writeExecutable("""
        #!/bin/sh
        if [ "$1" = list ]; then printf 'agent\\n'; exit 0; fi
        shift 2
        if [ "$#" = 0 ]; then printf 'attached\\n'; else exec "$@"; fi
        """, path: executable)
        let ssh = dir.appendingPathComponent("ssh").path
        try writeExecutable("""
        #!/bin/sh
        for argument do remote=$argument; done
        exec /bin/tcsh -f -c "$remote"
        """, path: ssh)
        let binding = try RemoteZmxBinding(endpoint: RemoteZmxEndpoint(destination: "host", executable: executable), session: "agent")
        let command = binding.startupCommand(sshArguments: [], sshExecutable: ssh,
            create: create, reconnectMessage: "retry", missingMessage: "missing",
            command: "printf 'created\\n'\nprintf 'multiline α\\n'")
        let result = try run(command, in: dir)
        #expect(result.status == 0)
        #expect(result.output == (create ? "created\nmultiline α\n" : "attached\n"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ script: String, path: String) throws {
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private func run(_ script: String, in directory: URL, environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
