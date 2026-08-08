import SwiftUI
import WidgetKit

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
    @State private var displayLanguage: DisplayLanguage

    init() {
        let controller = UsageController()
        _controller = StateObject(wrappedValue: controller)
        _displayLanguage = State(initialValue: DisplayLanguagePreferences.load())

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
            MenuContent(controller: controller, displayLanguage: $displayLanguage)
                .frame(width: 300)
                .environment(\.locale, displayLanguage.locale)
                .onChange(of: displayLanguage) { _, newLanguage in
                    DisplayLanguagePreferences.save(newLanguage)
                    WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.widgetKind)
                }
        } label: {
            Label {
                AppLocalizedText("Codex Rate")
            } icon: {
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
                .environment(\.locale, displayLanguage.locale)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    @Environment(\.locale) private var locale
    @ObservedObject var controller: UsageController
    @Binding var displayLanguage: DisplayLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    AppLocalizedText("Codex Remaining Capacity")
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
                .help(AppLocalization.string("Refresh now", locale: locale))
            }

            HStack(spacing: 12) {
                LimitCard(
                    title: AppLocalization.string("5 hours", locale: locale),
                    window: controller.snapshot.fiveHour
                )
                LimitCard(
                    title: AppLocalization.string("Weekly", locale: locale),
                    window: controller.snapshot.weekly
                )
            }

            WeeklyResetRow(window: controller.snapshot.weekly)

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            )) {
                AppLocalizedText("Launch at Login")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                Label {
                    AppLocalizedText("Language")
                } icon: {
                    Image(systemName: "globe")
                }
                    .font(.callout)
                Spacer()
                Picker(selection: $displayLanguage) {
                    ForEach(DisplayLanguage.allCases, id: \.self) { language in
                        Text(verbatim: language.displayName(locale: locale))
                            .tag(language)
                    }
                } label: {
                    AppLocalizedText("Language")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: AppLocalization.string("Language", locale: locale)))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AppLocalizedText("Widget syncs every 15 minutes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let version = BuildVersionInfo.current {
                    Text(verbatim: version.compactLabel)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityLabel(Text(verbatim: version.accessibilityLabel(locale: locale)))
                }
                Button { NSApplication.shared.terminate(nil) } label: {
                    AppLocalizedText("Quit")
                }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    private var updatedText: String {
        guard controller.snapshot.updatedAt != .distantPast else {
            return AppLocalization.string("Not fetched", locale: locale)
        }
        return AppLocalization.format(
            "Updated %@",
            locale: locale,
            controller.snapshot.updatedAt.formatted(
                .dateTime.hour().minute().locale(locale)
            )
        )
    }
}

private struct WeeklyResetRow: View {
    @Environment(\.locale) private var locale
    let window: RateLimitWindow?

    var body: some View {
        if let window {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    AppLocalizedText("Weekly reset")
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if let resetDate = window.resetDate {
                    if let remaining = ResetScheduleFormatting.remainingDuration(
                        until: resetDate,
                        locale: locale
                    ) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: ResetScheduleFormatting.dateTime(resetDate, locale: locale))
                            Text(AppLocalization.format("%@ remaining", locale: locale, remaining))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .monospacedDigit()
                    } else {
                        AppLocalizedText("Refresh to update the weekly reset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    AppLocalizedText("Weekly reset time unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LimitCard: View {
    @Environment(\.locale) private var locale
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
        guard let window else { return AppLocalization.string("Unavailable", locale: locale) }
        guard let date = window.resetDate else {
            return AppLocalization.string("Reset time unknown", locale: locale)
        }
        return AppLocalization.format(
            "Resets %@",
            locale: locale,
            date.formatted(
                .relative(presentation: .named, unitsStyle: .abbreviated)
                    .locale(locale)
            )
        )
    }
}
