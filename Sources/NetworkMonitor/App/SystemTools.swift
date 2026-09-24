import Darwin
import Foundation

enum ShellCommand {
    struct Result {
        let status: Int32
        let output: String

        var succeeded: Bool { status == 0 }
    }

    static func run(_ executable: String, _ arguments: [String]) async -> Result {
        await Task.detached { runSync(executable, arguments) }.value
    }

    static func runSync(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: process.terminationStatus, output: output)
    }
}

enum NetworkInterfaces {
    /// IPv4 addresses of the Mac's non-loopback Ethernet/Wi-Fi interfaces.
    static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(first) }

        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_UP != 0,
                  String(cString: interface.ifa_name).hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                addresses.append(String(cString: host))
            }
        }
        return addresses
    }
}

enum SystemProxy {
    private static let networksetup = "/usr/sbin/networksetup"

    static func preferredService() async -> String {
        let result = await ShellCommand.run(networksetup, ["-listallnetworkservices"])
        let services = result.output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") && !$0.isEmpty }
        return services.first { $0 == "Wi-Fi" } ?? services.first ?? "Wi-Fi"
    }

    static func enable(port: Int) async -> ShellCommand.Result {
        let service = await preferredService()
        let web = await ShellCommand.run(networksetup, ["-setwebproxy", service, "127.0.0.1", "\(port)"])
        guard web.succeeded else { return web }
        return await ShellCommand.run(networksetup, ["-setsecurewebproxy", service, "127.0.0.1", "\(port)"])
    }

    static func disable() async -> ShellCommand.Result {
        let service = await preferredService()
        let web = await ShellCommand.run(networksetup, ["-setwebproxystate", service, "off"])
        guard web.succeeded else { return web }
        return await ShellCommand.run(networksetup, ["-setsecurewebproxystate", service, "off"])
    }

    static func disableSync() {
        let list = ShellCommand.runSync(networksetup, ["-listallnetworkservices"])
        let services = list.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") }
        let service = services.first { $0 == "Wi-Fi" } ?? services.first ?? "Wi-Fi"
        _ = ShellCommand.runSync(networksetup, ["-setwebproxystate", service, "off"])
        _ = ShellCommand.runSync(networksetup, ["-setsecurewebproxystate", service, "off"])
    }
}
