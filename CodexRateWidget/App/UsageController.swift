import Foundation
import ServiceManagement
import WidgetKit

@MainActor
final class UsageController: ObservableObject {
    @Published private(set) var snapshot = SharedUsageStore.load()
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage = SharedUsageStore.lastError
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let client = CodexRateLimitClient()
    private var refreshLoop: Task<Void, Never>?

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let newSnapshot = try await client.fetch()
            try SharedUsageStore.save(newSnapshot)
            snapshot = newSnapshot
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.widgetKind)
        } catch {
            errorMessage = error.localizedDescription
            SharedUsageStore.save(error: error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }
}
