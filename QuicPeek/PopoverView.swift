import SwiftUI
import FoundationModels

struct PopoverView: View {
    @State private var prompt: String = ""
    @State private var response: String = ""
    @State private var status: String = ""
    @State private var isGenerating: Bool = false
    @State private var session = LanguageModelSession()
    @StateObject private var auth = PeecOAuth.shared
    @Environment(\.openSettings) private var openSettings
    @FocusState private var inputFocused: Bool

    private var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            responseArea

            inputBar
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            inputFocused = true
            status = availabilityMessage()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            peecStatus
            Spacer()
            settingsMenu
        }
    }

    @ViewBuilder
    private var peecStatus: some View {
        if auth.isConnected {
            Label("Peec", systemImage: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if auth.isConnecting {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button {
                Task { await auth.connect() }
            } label: {
                Label("Connect Peec", systemImage: "link")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit QuicPeek") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var responseArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !response.isEmpty {
                    Text(response)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 40, maxHeight: 240)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $prompt)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { Task { await send() } }
                .disabled(isGenerating)

            if isGenerating {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func availabilityMessage() -> String {
        switch availability {
        case .available:
            return ""
        case .unavailable(.deviceNotEligible):
            return "This Mac isn't eligible for Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence model is still downloading. Try again in a few minutes."
        case .unavailable(let other):
            return "Model unavailable: \(String(describing: other))"
        @unknown default:
            return "Model unavailable (unknown reason)."
        }
    }

    @MainActor
    private func send() async {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isGenerating else { return }

        if case .unavailable = availability {
            status = availabilityMessage()
            return
        }

        prompt = ""
        response = ""
        status = "Thinking…"
        isGenerating = true
        defer { isGenerating = false }

        do {
            let stream = session.streamResponse(to: input)
            for try await partial in stream {
                response = partial.content
                status = ""
            }
            if response.isEmpty {
                status = "Model returned an empty response."
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}
