import Foundation

struct PortProcess: Identifiable {
    let id: String        // "\(pid):\(port)" — stable dedup key
    let pid: Int32        // pid_t — matches Darwin kill() exactly
    let port: Int
    let rawCommand: String
    let displayName: String
    let address: String   // "*", "127.0.0.1", "[::1]", etc.
    let isSystem: Bool
    let isHMR: Bool
    let cwd: String?          // working directory of the process
    let projectName: String?  // name from package.json/go.mod/etc.
}

/// One visible row within a project submenu — all ports belonging to the same PID
struct ProjectEntry {
    let pid: Int32
    let displayName: String   // from the primary (non-HMR) process, or first if all HMR
    let ports: [PortProcess]  // all ports for this PID, sorted by port number
}

/// A group of related processes sharing the same working directory
struct Project {
    let name: String           // projectName ?? displayName of first entry ?? cwd last component
    let cwd: String?
    let entries: [ProjectEntry]
    let isSystem: Bool
}
