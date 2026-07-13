import SwiftUI

/// City Power Rankings (PRD Screen C) is Phase 6 scope. This is a clearly-marked placeholder so
/// the bottom bar's second destination exists and routes somewhere sensible in the meantime —
/// no ranking logic, phrase-bank content, or scoring belongs here yet.
struct RankingsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "list.number")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Coming Soon")
                    .font(.title3.weight(.semibold))
                Text("City Power Rankings arrive in a later phase.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Rankings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
