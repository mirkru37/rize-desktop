import AppKit
import Foundation
import SwiftUI

/// SwiftUI content hosted inside an `NSHostingView` attached to the status
/// item's menu (see `AppDelegate`), per
/// `documentation/architecture-desktop.md` §Component Diagram: today's
/// tracked time, top apps, live tracking state with a pause/resume control,
/// and Accessibility-permission onboarding.
struct MenuContentView: View {
    let viewModel: MenuContentViewModel

    @State private var showsLoginSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if viewModel.showsAccessibilityOnboarding {
                accessibilityOnboarding
            }
            todaySummary
            if !viewModel.topApps.isEmpty {
                topAppsList
            }
            if let authSession = viewModel.authSession {
                Divider()
                authAndSyncSection(authSession)
            }
        }
        .padding()
        .frame(width: 280)
        .sheet(isPresented: $showsLoginSheet) {
            if let authSession = viewModel.authSession {
                LoginView(authSession: authSession) {
                    showsLoginSheet = false
                }
            }
        }
    }

    /// The sign-in entry point (signed out) or account/sync status
    /// (signed in), per the RIZ-41 brief's "minimal login UI ... sync status
    /// in the menu (signed-in state, last sync time)" requirement.
    @ViewBuilder
    private func authAndSyncSection(_ authSession: AuthSessionViewModel) -> some View {
        if authSession.isSignedIn {
            VStack(alignment: .leading, spacing: 4) {
                if let email = authSession.userEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(syncStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Sign Out") {
                    Task { await authSession.logout() }
                }
                .font(.caption)
            }
        } else {
            Button("Sign In") {
                showsLoginSheet = true
            }
        }
    }

    private var syncStatusText: String {
        guard let syncStatus = viewModel.syncStatus else {
            return "Sync not configured"
        }
        if syncStatus.isSyncing {
            return "Syncing…"
        }
        if let lastSyncedAt = syncStatus.lastSyncedAt {
            return "Last synced \(lastSyncedAt.formatted(date: .omitted, time: .shortened))"
        }
        if syncStatus.lastErrorMessage != nil {
            return "Sync failed — will retry"
        }
        return "Not yet synced"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("RizeClone")
                    .font(.headline)
                Text(viewModel.displayState.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(viewModel.isPaused ? "Resume" : "Pause") {
                Task { await viewModel.togglePause() }
            }
        }
    }

    private var todaySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.totalTrackedTimeText)
                .font(.title2)
                .bold()
        }
    }

    private var topAppsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top apps")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(viewModel.topApps) { app in
                appRow(app)
            }
        }
    }

    private func appRow(_ app: ActivityAggregation.AppUsage) -> some View {
        HStack {
            Text(app.bundleID)
                .lineLimit(1)
            Spacer()
            Text(ActivityAggregation.formatDuration(app.duration))
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    private var accessibilityOnboarding: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility permission needed")
                .font(.subheadline)
                .bold()
            Text("RizeClone needs Accessibility access to record window titles. Grant it in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open System Settings") {
                openAccessibilityPrivacyPane()
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Deep-links into the Accessibility privacy pane, per
    /// `documentation/architecture-desktop.md` §Permissions & Entitlements.
    private func openAccessibilityPrivacyPane() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

#if DEBUG
    private final class PreviewLocalStore: LocalStore {
        func writeEvent(_ event: ActivityEvent) async throws {}
        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}
        func fetchTodayActivity() async throws -> [ActivityEvent] {
            []
        }

        func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
            []
        }

        func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {}
    }

    private actor PreviewEngine: TrackingEngineControlling {
        var state: TrackingLifecycleState {
            .active
        }

        var permissionState: AccessibilityPermissionState {
            .granted
        }

        var isPaused: Bool {
            false
        }

        func pause() async {}
        func resume() async {}
    }

    #Preview {
        MenuContentView(viewModel: MenuContentViewModel(store: PreviewLocalStore(), engine: PreviewEngine()))
    }
#endif
