import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

enum AppDiagnostics {
    private static var fileURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("com.codex.SevenDaySchedule", isDirectory: true)
            .appendingPathComponent("status.log")
    }

    static func write(_ message: String) {
        guard let fileURL else { return }
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
        }
    }
}

struct ScheduleItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var notes: String
    var startDate: Date
    var reminderMinutes: Int
    var repeatsWeekly: Bool?

    init(id: UUID = UUID(), title: String, notes: String = "", startDate: Date, reminderMinutes: Int = 10, repeatsWeekly: Bool = false) {
        self.id = id
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.reminderMinutes = reminderMinutes
        self.repeatsWeekly = repeatsWeekly
    }
}

struct ScheduleOccurrence: Identifiable {
    let source: ScheduleItem
    let startDate: Date

    var id: String {
        "\(source.id.uuidString)-\(Int(startDate.timeIntervalSince1970))"
    }
}

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var items: [ScheduleItem] = []
    @Published var errorMessage: String?

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("com.codex.SevenDaySchedule", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("schedules.json")
        load()
        rescheduleAllReminders()
    }

    func add(_ item: ScheduleItem) {
        items.append(item)
        normalizeAndSave()
        ReminderCenter.shared.schedule(item)
    }

    func update(_ item: ScheduleItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        normalizeAndSave()
        ReminderCenter.shared.schedule(item)
    }

    func delete(_ item: ScheduleItem) {
        items.removeAll { $0.id == item.id }
        normalizeAndSave()
        ReminderCenter.shared.remove(item.id)
    }

    func occurrences(on date: Date) -> [ScheduleOccurrence] {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)

        return items.compactMap { item in
            let itemDay = calendar.startOfDay(for: item.startDate)
            let isOccurrence: Bool

            if item.repeatsWeekly == true {
                let days = calendar.dateComponents([.day], from: itemDay, to: targetDay).day ?? -1
                isOccurrence = days >= 0 && days % 7 == 0
            } else {
                isOccurrence = calendar.isDate(item.startDate, inSameDayAs: targetDay)
            }

            guard isOccurrence else { return nil }
            let time = calendar.dateComponents([.hour, .minute, .second], from: item.startDate)
            let occurrenceDate = calendar.date(bySettingHour: time.hour ?? 0,
                                               minute: time.minute ?? 0,
                                               second: time.second ?? 0,
                                               of: targetDay) ?? targetDay
            return ScheduleOccurrence(source: item, startDate: occurrenceDate)
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            items = try JSONDecoder().decode([ScheduleItem].self, from: data)
            items.sort { $0.startDate < $1.startDate }
        } catch {
            errorMessage = "读取日程失败：\(error.localizedDescription)"
        }
    }

    private func normalizeAndSave() {
        items.sort { $0.startDate < $1.startDate }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            errorMessage = "保存日程失败：\(error.localizedDescription)"
        }
    }

    private func rescheduleAllReminders() {
        ReminderCenter.shared.removeOrphanedReminders(validIDs: Set(items.map { $0.id.uuidString }))
        for item in items where item.repeatsWeekly == true || item.startDate > Date() {
            ReminderCenter.shared.schedule(item)
        }
    }
}

final class ReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderCenter()
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppDiagnostics.write("通知授权失败：\(error.localizedDescription)")
            } else {
                AppDiagnostics.write(granted ? "通知提醒：已授权" : "通知提醒：未授权")
            }
        }
    }

    func schedule(_ item: ScheduleItem) {
        let identifier = item.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let fireDate = item.startDate.addingTimeInterval(TimeInterval(-max(0, item.reminderMinutes) * 60))
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = item.title
        if item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = item.reminderMinutes == 0 ? "日程现在开始" : "日程将在 \(item.reminderMinutes) 分钟后开始"
        } else {
            content.body = item.notes
        }
        content.sound = .default
        content.userInfo = ["scheduleID": identifier]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger: UNCalendarNotificationTrigger
        if item.repeatsWeekly == true {
            let weeklyComponents = Calendar.current.dateComponents([.weekday, .hour, .minute, .second], from: fireDate)
            trigger = UNCalendarNotificationTrigger(dateMatching: weeklyComponents, repeats: true)
        } else {
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    func remove(_ id: UUID) {
        let identifier = id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func removeOrphanedReminders(validIDs: Set<String>) {
        center.getPendingNotificationRequests { requests in
            let orphaned = requests.map(\.identifier).filter { !validIDs.contains($0) }
            guard !orphaned.isEmpty else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: orphaned)
            self.center.removeDeliveredNotifications(withIdentifiers: orphaned)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published var enabled = false
    @Published var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    func enableIfNeeded() {
        guard SMAppService.mainApp.status != .enabled else {
            refresh()
            AppDiagnostics.write("开机自动启动：已启用")
            return
        }
        do {
            try SMAppService.mainApp.register()
            refresh()
            AppDiagnostics.write(enabled ? "开机自动启动：已启用" : "开机自动启动：等待系统批准")
        } catch {
            errorMessage = "无法开启开机启动：\(error.localizedDescription)"
            AppDiagnostics.write("开机自动启动失败：\(error.localizedDescription)")
            refresh()
        }
    }

    func setEnabled(_ newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "更新开机启动失败：\(error.localizedDescription)"
            AppDiagnostics.write("更新开机自动启动失败：\(error.localizedDescription)")
        }
        refresh()
        AppDiagnostics.write(enabled ? "开机自动启动：已启用" : "开机自动启动：已关闭")
    }
}

private extension DateFormatter {
    static let dayTitle: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "M月d日 EEEE"
        return value
    }()

    static let timeOnly: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.dateFormat = "HH:mm"
        return value
    }()
}

struct ScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: ScheduleItem?
    let onSave: (ScheduleItem) -> Void

    @State private var title: String
    @State private var notes: String
    @State private var startDate: Date
    @State private var reminderMinutes: Int
    @State private var repeatsWeekly: Bool

    init(item: ScheduleItem?, onSave: @escaping (ScheduleItem) -> Void) {
        original = item
        self.onSave = onSave
        let defaultDate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        _title = State(initialValue: item?.title ?? "")
        _notes = State(initialValue: item?.notes ?? "")
        _startDate = State(initialValue: item?.startDate ?? defaultDate)
        _reminderMinutes = State(initialValue: item?.reminderMinutes ?? 10)
        _repeatsWeekly = State(initialValue: item?.repeatsWeekly == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "新建日程" : "编辑日程")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("标题").font(.caption).foregroundStyle(.secondary)
                TextField("例如：项目周会", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("开始时间").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("提醒").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("提前")
                    TextField("10", value: $reminderMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Text("分钟")
                    Stepper("", value: $reminderMinutes, in: 0...10080)
                        .labelsHidden()
                }
            }

            Toggle(isOn: $repeatsWeekly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每周重复")
                    Text("从所选日期开始，每周同一天、同一时间重复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                Text("备注（可选）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(height: 72)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    let value = ScheduleItem(
                        id: original?.id ?? UUID(),
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                        startDate: startDate,
                        reminderMinutes: min(max(reminderMinutes, 0), 10080),
                        repeatsWeekly: repeatsWeekly
                    )
                    onSave(value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}

struct ScheduleRow: View {
    let occurrence: ScheduleOccurrence
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var item: ScheduleItem { occurrence.source }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 12) {
                    Text(DateFormatter.timeOnly.string(from: occurrence.startDate))
                        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 48, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if item.repeatsWeekly == true {
                                Image(systemName: "repeat").font(.caption2)
                                Text("每周")
                                Text("·")
                            }
                            Image(systemName: "bell.fill").font(.caption2)
                            Text(item.reminderMinutes == 0 ? "准时提醒" : "提前 \(item.reminderMinutes) 分钟")
                            if !item.notes.isEmpty {
                                Text("·")
                                Text(item.notes).lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)
                }
            }
            .buttonStyle(.plain)
            .help("点击编辑日程")

            HStack(spacing: 2) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 5)
        .background(hovering ? Color.accentColor.opacity(0.09) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct DaySection: View {
    @EnvironmentObject private var store: ScheduleStore
    let date: Date
    let isToday: Bool
    let onEdit: (ScheduleItem) -> Void

    var body: some View {
        let dayItems = store.occurrences(on: date)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(DateFormatter.dayTitle.string(from: date))
                    .font(.headline)
                if isToday {
                    Text("今天")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
                Spacer()
                Text("\(dayItems.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if dayItems.isEmpty {
                Text("暂无日程")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(dayItems) { occurrence in
                    ScheduleRow(occurrence: occurrence,
                                onEdit: { onEdit(occurrence.source) },
                                onDelete: { store.delete(occurrence.source) })
                    if occurrence.id != dayItems.last?.id { Divider() }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }
}

struct ContentView: View {
    struct EditorContext: Identifiable {
        let id = UUID()
        let item: ScheduleItem?
    }

    @EnvironmentObject private var store: ScheduleStore
    @EnvironmentObject private var loginItem: LoginItemController
    @State private var editorContext: EditorContext?

    private var days: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("七日日程")
                        .font(.title2.bold())
                    Text("今天起未来 7 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Toggle("开机自动启动", isOn: Binding(
                        get: { loginItem.enabled },
                        set: { loginItem.setEnabled($0) }
                    ))
                    Divider()
                    Button("退出七日日程") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)

                Button {
                    editorContext = EditorContext(item: nil)
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, date in
                        DaySection(date: date, isToday: index == 0) { item in
                            editorContext = EditorContext(item: item)
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 430, height: 650)
        .background(.ultraThinMaterial)
        .sheet(item: $editorContext) { context in
            ScheduleEditor(item: context.item) { item in
                if context.item == nil { store.add(item) } else { store.update(item) }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { store.errorMessage != nil || loginItem.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil; loginItem.errorMessage = nil } }
        )) {
            Button("好") {
                store.errorMessage = nil
                loginItem.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? loginItem.errorMessage ?? "")
        }
        .onAppear { loginItem.refresh() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = ScheduleStore()
    private let loginItem = LoginItemController()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDiagnostics.write("应用已启动（版本 1.0）")
        NSApp.setActivationPolicy(.accessory)
        ReminderCenter.shared.requestAuthorization()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "七日日程")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.contentSize = NSSize(width: 430, height: 650)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(store)
                .environmentObject(loginItem)
        )

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        loginItem.enableIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.showPopover(relativeTo: button)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

@main
struct SevenDayScheduleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
