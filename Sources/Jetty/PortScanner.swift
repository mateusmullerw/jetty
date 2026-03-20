import Foundation
import Darwin

final class PortScanner {

    // MARK: - Public API

    static func scan() -> [PortProcess] {
        let raw = runLsof()
        return parse(raw)
    }

    static func scanProjects() -> [Project] {
        buildProjects(scan())
    }

    // MARK: - lsof execution

    private static func runLsof() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcn"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do { try task.run() } catch { return "" }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Parsing

    private static func parse(_ output: String) -> [PortProcess] {
        var raw: [PortProcess] = []

        var currentPID: Int32 = 0
        var currentCommand: String = ""
        var seenPorts: Set<String> = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())

            switch first {
            case "p":
                currentPID = Int32(value) ?? 0
                currentCommand = ""
                seenPorts = []

            case "c":
                currentCommand = value

            case "n":
                guard currentPID > 0, !currentCommand.isEmpty else { continue }
                guard let colonIdx = value.lastIndex(of: ":") else { continue }
                let portStr = String(value[value.index(after: colonIdx)...])
                guard let portNum = Int(portStr), portNum > 0 else { continue }

                let dedupeKey = "\(currentPID):\(portNum)"
                guard !seenPorts.contains(dedupeKey) else { continue }
                seenPorts.insert(dedupeKey)

                let address = String(value[..<colonIdx])
                let displayName = humanReadableName(for: currentCommand, port: portNum)

                raw.append(PortProcess(
                    id: dedupeKey,
                    pid: currentPID,
                    port: portNum,
                    rawCommand: currentCommand,
                    displayName: displayName,
                    address: address.isEmpty ? "*" : address,
                    isSystem: isSystemProcess(command: currentCommand),
                    isHMR: false,  // filled in by tagHMRPorts()
                    cwd: nil,      // filled in below
                    projectName: nil
                ))

            default:
                break
            }
        }

        // Tag HMR ports
        let tagged = tagHMRPorts(raw)

        // Enrich with CWD + project name (one proc_pidinfo call per unique PID)
        let uniquePIDs = Set(tagged.map(\.pid))
        var cwdByPID: [Int32: String] = [:]
        for pid in uniquePIDs {
            cwdByPID[pid] = getCWD(pid: pid)
        }

        // One project-name lookup per unique CWD
        var projectNameByCWD: [String: String?] = [:]
        for cwd in Set(cwdByPID.values.compactMap { $0 }) {
            projectNameByCWD[cwd] = getProjectName(cwd: cwd)
        }

        let enriched = tagged.map { p -> PortProcess in
            let cwd = cwdByPID[p.pid]
            let projectName: String? = cwd.flatMap { projectNameByCWD[$0] ?? nil }
            return PortProcess(
                id: p.id, pid: p.pid, port: p.port,
                rawCommand: p.rawCommand, displayName: p.displayName,
                address: p.address, isSystem: p.isSystem, isHMR: p.isHMR,
                cwd: cwd, projectName: projectName
            )
        }

        return enriched.sorted { $0.port < $1.port }
    }

    // MARK: - HMR detection

    private static func tagHMRPorts(_ processes: [PortProcess]) -> [PortProcess] {
        let byPID = Dictionary(grouping: processes, by: \.pid)

        let pidsWithPublicPort = Set(byPID.compactMap { (pid, ports) -> Int32? in
            ports.contains(where: { isPublicAddress($0.address) }) ? pid : nil
        })

        return processes.map { p in
            guard !isPublicAddress(p.address), pidsWithPublicPort.contains(p.pid) else { return p }
            return PortProcess(
                id: p.id, pid: p.pid, port: p.port,
                rawCommand: p.rawCommand, displayName: p.displayName,
                address: p.address, isSystem: p.isSystem, isHMR: true,
                cwd: p.cwd, projectName: p.projectName
            )
        }
    }

    private static func isPublicAddress(_ address: String) -> Bool {
        address == "*" || (!address.hasPrefix("127.") && !address.hasPrefix("[::1]") && !address.isEmpty)
    }

    // MARK: - Project grouping

    static func buildProjects(_ processes: [PortProcess]) -> [Project] {
        let dev    = processes.filter { !$0.isSystem }
        let system = processes.filter {  $0.isSystem }

        let devProjects    = group(dev,    isSystem: false)
        let systemProjects = group(system, isSystem: true)

        return devProjects + systemProjects
    }

    private static func group(_ processes: [PortProcess], isSystem: Bool) -> [Project] {
        // Bucket by CWD; nil CWD → each unique PID is its own project
        var cwdOrder: [String] = []
        var cwdMap: [String: [PortProcess]] = [:]
        var noCWD: [PortProcess] = []

        for p in processes {
            if let cwd = p.cwd {
                if cwdMap[cwd] == nil { cwdOrder.append(cwd) }
                cwdMap[cwd, default: []].append(p)
            } else {
                noCWD.append(p)
            }
        }

        var groups: [(cwd: String?, processes: [PortProcess])] = []
        for cwd in cwdOrder { groups.append((cwd: cwd, processes: cwdMap[cwd]!)) }

        // noCWD: one project per unique PID (preserving encounter order)
        var seenNoCWD = Set<Int32>()
        var noCWDByPID: [Int32: [PortProcess]] = [:]
        var noCWDPIDOrder: [Int32] = []
        for p in noCWD {
            if seenNoCWD.insert(p.pid).inserted { noCWDPIDOrder.append(p.pid) }
            noCWDByPID[p.pid, default: []].append(p)
        }
        for pid in noCWDPIDOrder { groups.append((cwd: nil, processes: noCWDByPID[pid]!)) }

        let projects: [Project] = groups.map { group in
            // Within each CWD group, group all ports by PID → one ProjectEntry per PID
            var pidOrder: [Int32] = []
            var pidMap: [Int32: [PortProcess]] = [:]
            var seenPIDs = Set<Int32>()
            for p in group.processes {
                if seenPIDs.insert(p.pid).inserted { pidOrder.append(p.pid) }
                pidMap[p.pid, default: []].append(p)
            }

            let entries: [ProjectEntry] = pidOrder.map { pid in
                let pidPorts = pidMap[pid]!.sorted { $0.port < $1.port }
                // Prefer a non-HMR port's display name as the entry label
                let displayName = pidPorts.first(where: { !$0.isHMR })?.displayName
                               ?? pidPorts.first?.displayName
                               ?? "Unknown"
                return ProjectEntry(pid: pid, displayName: displayName, ports: pidPorts)
            }

            let name: String
            if let projectName = group.processes.first?.projectName {
                // Found a project manifest (package.json, go.mod, etc.)
                name = projectName
            } else if let cwd = group.cwd {
                if cwd == "/" {
                    // Root filesystem — root-owned system processes
                    name = "root"
                } else {
                    let lastComp = URL(fileURLWithPath: cwd).lastPathComponent
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    // Use the folder name only for genuine user project directories
                    // (under home, but not inside ~/Library or ~/Applications)
                    let isUserProjectDir = cwd.hasPrefix(home)
                        && !cwd.hasPrefix(home + "/Library")
                        && !cwd.hasPrefix(home + "/Applications")
                    name = isUserProjectDir
                        ? lastComp
                        : (group.processes.first?.displayName ?? lastComp)
                }
            } else {
                name = group.processes.first?.displayName ?? "Unknown"
            }

            return Project(name: name, cwd: group.cwd, entries: entries, isSystem: isSystem)
        }

        return projects.sorted { a, b in
            if a.cwd != nil && b.cwd == nil { return true }
            if a.cwd == nil && b.cwd != nil { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - CWD detection via proc_pidinfo

    private static func getCWD(pid: Int32) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout.size(ofValue: pathInfo))
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, size)
        guard ret > 0 else { return nil }
        return withUnsafeBytes(of: pathInfo.pvi_cdir.vip_path) { buf in
            guard let ptr = buf.baseAddress else { return nil }
            let s = String(cString: ptr.assumingMemoryBound(to: CChar.self))
            return s.isEmpty ? nil : s
        }
    }

    // MARK: - Project name from CWD

    private static func getProjectName(cwd: String) -> String? {
        let base = URL(fileURLWithPath: cwd)

        // package.json → "name" (Node / Bun / Deno)
        if let data = try? Data(contentsOf: base.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }

        // go.mod → module path last component
        if let content = try? String(contentsOf: base.appendingPathComponent("go.mod"), encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("module ") {
                    let path = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    if let last = path.components(separatedBy: "/").last, !last.isEmpty {
                        return last
                    }
                }
            }
        }

        // Cargo.toml → [package] name
        if let content = try? String(contentsOf: base.appendingPathComponent("Cargo.toml"), encoding: .utf8) {
            var inPackage = false
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "[package]" { inPackage = true; continue }
                if trimmed.hasPrefix("[") { inPackage = false; continue }
                if inPackage, trimmed.hasPrefix("name") {
                    let parts = trimmed.components(separatedBy: "=")
                    if parts.count >= 2 {
                        let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if !name.isEmpty { return name }
                    }
                }
            }
        }

        // pyproject.toml → [project] name
        if let content = try? String(contentsOf: base.appendingPathComponent("pyproject.toml"), encoding: .utf8) {
            var inProject = false
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "[project]" { inProject = true; continue }
                if trimmed.hasPrefix("[") { inProject = false; continue }
                if inProject, trimmed.hasPrefix("name") {
                    let parts = trimmed.components(separatedBy: "=")
                    if parts.count >= 2 {
                        let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if !name.isEmpty { return name }
                    }
                }
            }
        }

        // mix.exs → app: :name
        if let content = try? String(contentsOf: base.appendingPathComponent("mix.exs"), encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("app:") {
                    // app: :my_app
                    let parts = trimmed.components(separatedBy: ":")
                    if parts.count >= 3 {
                        let name = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))
                        if !name.isEmpty { return name }
                    }
                }
            }
        }

        return nil  // caller falls back to cwd last component or displayName
    }

    // MARK: - System process classification

    private static let systemCommands: Set<String> = [
        "ControlCenter", "rapportd", "sharingd", "AirPlayXPCHelper",
        "remoted", "ScreensharingAgent", "loginwindow",
        "logioptionsplus_agent",
        "figma_agent",
        "Cursor", "Cursor Helper (Plugin)",
        "Code Helper (Plugin)", "code",
        "Proxyman", "Charles", "mitmproxy",
        "TablePlus", "dbeaver",
    ]

    static func isSystemProcess(command: String) -> Bool {
        if systemCommands.contains(command) { return true }
        if command.hasPrefix("Cursor Helper") || command.hasPrefix("Code Helper") { return true }
        return false
    }

    // MARK: - Human-readable name mapping

    static func humanReadableName(for command: String, port: Int) -> String {
        let commandMap: [String: String] = [
            "node":                     "Node.js",
            "bun":                      "Bun",
            "deno":                     "Deno",
            "ruby":                     "Ruby",
            "python":                   "Python",
            "python3":                  "Python",
            "elixir":                   "Elixir",
            "beam.smp":                 "Elixir/Erlang",
            "java":                     "Java",
            "go":                       "Go",
            "php":                      "PHP",
            "php-fpm":                  "PHP-FPM",
            "puma":                     "Ruby/Puma",
            "unicorn":                  "Ruby/Unicorn",
            "gunicorn":                 "Python/Gunicorn",
            "uvicorn":                  "Python/Uvicorn",
            "nginx":                    "Nginx",
            "httpd":                    "Apache",
            "caddy":                    "Caddy",
            "postgres":                 "PostgreSQL",
            "mysqld":                   "MySQL",
            "mysqld_safe":              "MySQL",
            "redis-server":             "Redis",
            "mongod":                   "MongoDB",
            "memcached":                "Memcached",
            "elasticsearch":            "Elasticsearch",
            "clickhouse-server":        "ClickHouse",
            "ControlCenter":            "Control Center",
            "rapportd":                 "AirPlay/Handoff",
            "sharingd":                 "Sharing",
            "AirPlayXPCHelper":         "AirPlay",
            "com.docker.backend":       "Docker",
            "docker-proxy":             "Docker Proxy",
            "docker":                   "Docker CLI",
            "Cursor":                   "Cursor",
            "Cursor Helper (Plugin)":   "Cursor (Extension)",
            "Code Helper (Plugin)":     "VS Code (Extension)",
            "code":                     "VS Code",
            "figma_agent":              "Figma Agent",
            "TablePlus":                "TablePlus",
            "Proxyman":                 "Proxyman",
            "Charles":                  "Charles Proxy",
            "mitmproxy":                "mitmproxy",
            "ngrok":                    "ngrok",
            "logioptionsplus_agent":    "Logi Options+",
        ]

        if let mapped = commandMap[command] { return mapped }

        let prefixMap: [(prefix: String, display: String)] = [
            ("python", "Python"), ("ruby", "Ruby"), ("php", "PHP"), ("node", "Node.js"),
        ]
        for (prefix, display) in prefixMap {
            if command.hasPrefix(prefix) { return display }
        }

        let portHints: [Int: String] = [
            80: "HTTP", 443: "HTTPS",
            3000: "Dev :3000", 3001: "Dev :3001", 4000: "Dev :4000",
            4200: "Angular Dev", 5000: "Dev :5000", 5173: "Vite Dev",
            8000: "Dev :8000", 8080: "Dev :8080", 8443: "HTTPS Dev", 9000: "Dev :9000",
            5432: "PostgreSQL", 3306: "MySQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
        ]
        if command.count <= 6, let hint = portHints[port] {
            return "\(command) (\(hint))"
        }

        return command
    }
}
