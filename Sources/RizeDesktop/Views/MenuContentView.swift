import SwiftUI

/// Placeholder SwiftUI content for future use inside an `NSHostingView`
/// attached to the status item's menu. Not wired into the status item yet —
/// tracking-status UI is a later epic.
struct MenuContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RizeClone")
                .font(.headline)
            Text("Tracking: not yet implemented")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    MenuContentView()
}
