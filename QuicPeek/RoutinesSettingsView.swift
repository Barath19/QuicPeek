import SwiftUI
import SwiftData

struct RoutinesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Routine.createdAt, order: .reverse) private var routines: [Routine]
    @ObservedObject private var mcp = PeecMCP.shared
    @ObservedObject private var scheduler = RoutineScheduler.shared
    @State private var editing: Routine?
    @State private var showingAdd: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Routines")
                    .font(.headline)
                Spacer()
                if !scheduler.notificationsAuthorized {
                    Label("Notifications off", systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Enable notifications in System Settings to receive routine results.")
                }
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(mcp.projects.isEmpty)
                .help(mcp.projects.isEmpty
                      ? "Connect Peec AI to create routines"
                      : "Add a routine")
            }

            if routines.isEmpty {
                ContentUnavailableView(
                    "No routines yet",
                    systemImage: "calendar.badge.clock",
                    description: Text("Schedule a daily or weekly brief that arrives as a notification.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(routines) { routine in
                        RoutineRow(routine: routine, projects: mcp.projects)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = routine }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(routines[index])
                        }
                        save()
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(16)
        .sheet(isPresented: $showingAdd) {
            RoutineEditor(
                routine: nil,
                projects: mcp.projects,
                onSave: { draft in
                    modelContext.insert(draft)
                    save()
                }
            )
        }
        .sheet(item: $editing) { routine in
            RoutineEditor(
                routine: routine,
                projects: mcp.projects,
                onSave: { _ in
                    save()
                }
            )
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            // Surface to console; SwiftData errors here are usually constraint or
            // disk-full conditions worth knowing about.
            print("[Routines] save failed:", error.localizedDescription)
        }
    }
}

private struct RoutineRow: View {
    @Bindable var routine: Routine
    let projects: [PeecMCP.Project]

    private var projectName: String {
        projects.first(where: { $0.id == routine.projectID })?.name ?? "Unknown project"
    }

    private var lastRun: RoutineRun? {
        routine.runs.sorted { $0.startedAt > $1.startedAt }.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $routine.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name)
                    .font(.callout).fontWeight(.medium)
                Text(routine.scheduleDescription())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(projectName)
                        .font(.caption2)
                    if let last = lastRun {
                        Text("·")
                            .font(.caption2)
                        Image(systemName: last.didSucceed
                              ? "checkmark.circle.fill"
                              : (last.errorText != nil ? "exclamationmark.circle.fill" : "clock"))
                            .font(.system(size: 9))
                            .foregroundStyle(last.didSucceed ? .green
                                             : (last.errorText != nil ? .red : .secondary))
                        Text(last.startedAt, style: .relative)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Run now") {
                RoutineScheduler.shared.runNow(routine)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

private struct RoutineEditor: View {
    let routine: Routine?
    let projects: [PeecMCP.Project]
    let onSave: (Routine) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var cadence: RoutineCadence
    @State private var weekday: Int
    @State private var time: Date
    @State private var preset: RoutinePreset
    @State private var customPrompt: String
    @State private var projectID: String
    @State private var isEnabled: Bool

    init(routine: Routine?, projects: [PeecMCP.Project], onSave: @escaping (Routine) -> Void) {
        self.routine = routine
        self.projects = projects
        self.onSave = onSave

        let cal = Calendar.current
        var comps = DateComponents()
        comps.hour = routine?.hour ?? 9
        comps.minute = routine?.minute ?? 0
        let initialTime = cal.date(from: comps) ?? Date()

        _name = State(initialValue: routine?.name ?? "Morning Brief")
        _cadence = State(initialValue: routine?.cadence ?? .daily)
        _weekday = State(initialValue: routine?.weekday ?? 2)
        _time = State(initialValue: initialTime)
        _preset = State(initialValue: routine?.preset ?? .morningBrief)
        _customPrompt = State(initialValue: routine?.customPrompt ?? "")
        _projectID = State(initialValue: routine?.projectID ?? projects.first?.id ?? "")
        _isEnabled = State(initialValue: routine?.isEnabled ?? true)
    }

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Toggle("Enabled", isOn: $isEnabled)
                }
                Section("Schedule") {
                    Picker("Cadence", selection: $cadence) {
                        ForEach(RoutineCadence.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    if cadence == .weekly {
                        Picker("Day", selection: $weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(calendar.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
                Section("Project") {
                    Picker("Project", selection: $projectID) {
                        ForEach(projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .disabled(projects.isEmpty)
                }
                Section("Prompt") {
                    Picker("Preset", selection: $preset) {
                        ForEach(RoutinePreset.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    if preset == .custom {
                        TextEditor(text: $customPrompt)
                            .frame(minHeight: 80)
                            .font(.callout)
                    } else {
                        Text(preset.defaultPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(routine == nil ? "Add" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 460, idealHeight: 540)
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !projectID.isEmpty else { return false }
        if preset == .custom, customPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    private func commit() {
        let comps = calendar.dateComponents([.hour, .minute], from: time)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0

        if let routine {
            // If the user moved the schedule earlier in the day or changed cadence, reset
            // lastRunAt so we don't fire instantly against the new earlier slot.
            let scheduleChanged =
                routine.cadence != cadence ||
                routine.hour != hour ||
                routine.minute != minute ||
                routine.weekday != weekday
            routine.name = name
            routine.cadence = cadence
            routine.hour = hour
            routine.minute = minute
            routine.weekday = weekday
            routine.preset = preset
            routine.customPrompt = customPrompt
            routine.projectID = projectID
            routine.isEnabled = isEnabled
            if scheduleChanged {
                routine.lastRunAt = .now
            }
            onSave(routine)
        } else {
            let new = Routine(
                name: name,
                cadence: cadence,
                hour: hour,
                minute: minute,
                weekday: weekday,
                preset: preset,
                customPrompt: customPrompt,
                projectID: projectID,
                isEnabled: isEnabled
            )
            onSave(new)
        }
        dismiss()
    }
}
