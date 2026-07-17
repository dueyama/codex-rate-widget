import SwiftUI

enum AppRuntime {
    static func shouldStartMonitoring(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // The application is the XCTest host. Starting the refresh loop here
        // would turn deterministic unit tests into live Codex account calls.
        environment["XCTestConfigurationFilePath"] == nil
    }
}

@main
@MainActor
struct CodexRateWidgetApp: App {
    @StateObject private var controller: UsageController

    init() {
        let controller = UsageController()
        _controller = StateObject(wrappedValue: controller)

        if AppRuntime.shouldStartMonitoring() {
            // A menu-bar-only app has no regular windows, so macOS may otherwise
            // consider it eligible for automatic termination. The host app must
            // stay alive to collect Codex usage and refresh the widget periodically.
            ProcessInfo.processInfo.disableAutomaticTermination("Codex usage monitoring")
            controller.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
                .frame(width: 300)
        } label: {
            Label("Codex Rate", systemImage: "gauge.with.dots.needle.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: UsageController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Remaining Capacity")
                        .font(.headline)
                    Text(updatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await controller.refresh() }
                } label: {
                    if controller.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(controller.isRefreshing)
                .help("Refresh now")
            }

            HStack(spacing: 12) {
                LimitCard(title: String(localized: "5 hours"), window: controller.snapshot.fiveHour)
                LimitCard(title: String(localized: "Weekly"), window: controller.snapshot.weekly)
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Widget syncs every 15 minutes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let version = BuildVersionInfo.current {
                    Text(verbatim: version.compactLabel)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityLabel(Text(verbatim: version.accessibilityLabel))
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    private var updatedText: String {
        guard controller.snapshot.updatedAt != .distantPast else { return String(localized: "Not fetched") }
        return String(
            format: String(localized: "Updated %@"),
            controller.snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
        )
    }
}

private struct LimitCard: View {
    let title: String
    let window: RateLimitWindow?

    var body: some View {
        VStack(spacing: 7) {
            Text(title).font(.caption.weight(.semibold))
            ZStack {
                Circle().stroke(.secondary.opacity(0.16), lineWidth: 7)
                if let window {
                    Circle()
                        .trim(from: 0, to: CGFloat(window.remainingPercent) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(window.remainingPercent)%")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                } else {
                    Image(systemName: "minus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var color: Color {
        guard let remaining = window?.remainingPercent else { return .secondary }
        if remaining <= 20 { return .red }
        if remaining <= 40 { return .orange }
        return .green
    }

    private var resetText: String {
        guard let window else { return String(localized: "Unavailable") }
        guard let date = window.resetDate else { return String(localized: "Reset time unknown") }
        return String(
            format: String(localized: "Resets %@"),
            date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        )
    }
}
