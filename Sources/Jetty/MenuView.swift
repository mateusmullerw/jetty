import SwiftUI

// MARK: - DividerWithPaddingView
struct DividerWithPadding: View {

    var body: some View {
        Divider()
        .padding(.horizontal, 14)
    }
}

// MARK: - MenuContentView
struct MenuContentView: View {
    @EnvironmentObject private var vm: PortViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView()
            DividerWithPadding()
            VStack(alignment: .leading, spacing: 0) {
                let devProjects    = vm.projects.filter { !$0.isSystem }
                let systemProjects = vm.projects.filter {  $0.isSystem }

                if devProjects.isEmpty && systemProjects.isEmpty {
                    Text(verbatim: "No processes listening")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 0)
                        .padding(.vertical, 8)
                } else {
                    if devProjects.isEmpty {
                        Text(verbatim: "No user processes listening")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 0)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(devProjects.enumerated()), id: \.element.name) { index, project in
                            if index > 0 { DividerWithPadding() }
                            ProjectSection(project: project)
                        }
                    }

                    if !systemProjects.isEmpty {
                        DividerWithPadding()
                        OthersSectionView(projects: systemProjects).padding(.vertical, 6).padding(.horizontal, 8)
                    }
                }
            }
            
            DividerWithPadding()
            
            QuitRow().padding(.vertical, 6).padding(.horizontal, 8)
        }.frame(width: 300)
        .alert(vm.killError?.title ?? "", isPresented: Binding(
            get: { vm.killError != nil },
            set: { if !$0 { vm.killError = nil } }
        )) {
            Button("OK") { vm.killError = nil }
        } message: {
            Text(vm.killError?.message ?? "")
        }
    }
}

// MARK: - HeaderView

struct HeaderView: View {
    @EnvironmentObject private var vm: PortViewModel

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.timeStyle = .medium
        return fmt.string(from: vm.lastRefreshDate)
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Jetty · Listening ports")
                    .font(.system(size: NSFont.systemFontSize + 2, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(verbatim: timeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await vm.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        
    }
}

// MARK: - ProjectSection

struct ProjectSection: View {
    let project: Project

    var body: some View {
        Text(verbatim: project.name)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)

        ForEach(project.entries, id: \.pid) { entry in
            PortEntryRow(entry: entry)
        }
    }
}

// MARK: - OthersSectionView

struct OthersSectionView: View {
    let projects: [Project]
    @State private var isHovered = false
    @State private var isExpanded = false

    private var totalEntries: Int {
        projects.flatMap(\.entries).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(verbatim: "Others (\(totalEntries))")
                        .font(.callout).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .buttonStyle(.plain)
            .background(
                Capsule()
                    .fill(isHovered ? Color.gray.opacity(0.4) : Color.clear)
            )
            .onHover { hovering in
                    isHovered = hovering
            }

            if isExpanded {
                ForEach(Array(projects.enumerated()), id: \.element.name) { index, project in
                    if index > 0 { DividerWithPadding() }
                    ProjectSection(project: project)
                }
            }
        }
    }
}

// MARK: - PortEntryRow

struct PortEntryRow: View {
    let entry: ProjectEntry
    @EnvironmentObject private var vm: PortViewModel

    private static func interfaceLabel(_ address: String) -> String {
        switch address {
        case "*", "0.0.0.0", "::", "0:0:0:0:0:0:0:0": return "All interfaces"
        case "127.0.0.1", "[::1]", "::1":              return "Local only"
        default:                                         return address
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(entry.displayName)  ·  PID \(entry.pid)")
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                    .padding(.top, 2)

                ForEach(entry.ports.sorted { $0.port < $1.port }) { port in
                    Text(verbatim: ":\(port.port)  ·  \(Self.interfaceLabel(port.address))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            KillButtonView {
                vm.kill(pid: entry.pid)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - KillButtonView

struct KillButtonView: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: "Kill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isHovered ? Color.white : .killRed)
           
            
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(isHovered ? .killRed : Color.clear)
        )
        .onHover { hovering in
           
                isHovered = hovering
            
        }
    }
}

// MARK: - QuitRow

struct QuitRow: View {
    @State private var isHovered = false
    
    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "power").font(.system(size: 12))
                Text(verbatim: "Quit Jetty")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(isHovered ? Color.gray.opacity(0.4) : Color.clear)
        )
        .onHover { hovering in
          
                isHovered = hovering
            
        }
    }
}


extension Color {
    static let killRed = Color(
        light: NSColor.systemRed.blended(withFraction: 0.2, of: .black)!,
        dark: NSColor.systemRed.blended(withFraction: 0.2, of: .white)!
    )
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.name == .darkAqua ? dark : light
        })
    }
}
