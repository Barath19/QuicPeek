import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("app.theme") private var theme: AppTheme = .system

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            PeecSettings()
                .tabItem { Label("Peec AI", systemImage: "link") }
        }
        .frame(width: 460, height: 280)
        .preferredColorScheme(theme.resolve())
        .background(WindowAppearance(appearance: theme.nsAppearance))
        .id(theme)
    }
}

private struct ToolGroup: View {
    let title: String
    let tools: [PeecMCP.MCPTool]
    @State private var expanded: Bool = false
    @StateObject private var policies = ToolPolicyStore.shared

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tools) { tool in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.title ?? tool.name)
                                .font(.callout).fontWeight(.medium)
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Picker("", selection: policies.binding(for: tool)) {
                            ForEach(ToolPolicy.allCases) { policy in
                                Label(policy.displayName, systemImage: policy.symbolName)
                                    .tag(policy)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout).fontWeight(.medium)
                Text("\(tools.count)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
        }
    }
}

private struct ProjectGroup: View {
    let title: String
    let projects: [PeecMCP.Project]
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(projects) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.callout).fontWeight(.medium)
                            Text(project.id)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(project.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout).fontWeight(.medium)
                Text("\(projects.count)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
        }
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @AppStorage("app.theme") private var theme: AppTheme = .system

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            error = nil
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            self.error = error.localizedDescription
                        }
                    }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PeecSettings: View {
    @StateObject private var auth = PeecOAuth.shared
    @StateObject private var mcp = PeecMCP.shared

    var body: some View {
        Form {
            Section("Connection") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(auth.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(auth.isConnected ? "Connected" : "Not connected")
                        .foregroundStyle(auth.isConnected ? .primary : .secondary)
                    Spacer()
                    if auth.isConnected {
                        Button("Disconnect", role: .destructive) {
                            auth.disconnect()
                            mcp.clear()
                        }
                    } else {
                        Button {
                            Task { await auth.connect() }
                        } label: {
                            if auth.isConnecting {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Connecting…")
                                }
                            } else {
                                Text("Connect to Peec AI")
                            }
                        }
                        .disabled(auth.isConnecting)
                    }
                }
                if let err = auth.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Text("Tools")
                        .font(.subheadline).fontWeight(.semibold)
                    Spacer()
                    if mcp.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(mcp.tools.isEmpty ? "Load" : "Refresh") {
                            Task { await mcp.refreshTools() }
                        }
                        .disabled(!auth.isConnected)
                        .controlSize(.small)
                    }
                }

                if let err = mcp.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else if mcp.tools.isEmpty && !mcp.isLoading {
                    Text(auth.isConnected ? "Click Load to fetch tools." : "Connect to Peec AI first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let readOnly = mcp.tools.filter { $0.readOnly }
                    let writeDelete = mcp.tools.filter { !$0.readOnly }

                    if !readOnly.isEmpty {
                        ToolGroup(title: "Read-only tools", tools: readOnly)
                    }
                    if !writeDelete.isEmpty {
                        ToolGroup(title: "Write/delete tools", tools: writeDelete)
                    }
                }
            }

            Section {
                HStack {
                    Text("Projects")
                        .font(.subheadline).fontWeight(.semibold)
                    Spacer()
                    Button(mcp.projects.isEmpty ? "Load" : "Refresh") {
                        Task { await mcp.refreshProjects() }
                    }
                    .disabled(!auth.isConnected || mcp.isLoading)
                    .controlSize(.small)
                }
                if mcp.projects.isEmpty {
                    Text(auth.isConnected ? "Click Load to fetch projects." : "Connect to Peec AI first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProjectGroup(title: "Active projects", projects: mcp.projects)
                }
            }

            Section {
                Text("QuicPeek connects to Peec AI over MCP using OAuth 2.0. Reports and chat context stay in your Peec AI account; only your questions are sent to Peec AI's MCP endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard auth.isConnected else { return }
            Task {
                if mcp.tools.isEmpty { await mcp.refreshTools() }
                if mcp.projects.isEmpty { await mcp.refreshProjects() }
            }
        }
    }
}

#Preview("Settings — Light") {
    SettingsView().preferredColorScheme(.light)
}

#Preview("Settings — Dark") {
    SettingsView().preferredColorScheme(.dark)
}
