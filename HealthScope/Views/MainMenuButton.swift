import SwiftUI

struct MainMenuButton: View {
    @EnvironmentObject private var profileViewModel: UserProfileViewModel

    let exportDisabled: Bool
    let onShowProfile: () -> Void
    let onShowConfiguration: () -> Void
    let onExport: () -> Void

    var body: some View {
        Menu {
            Button(action: onShowProfile) {
                Label("User Card", systemImage: "person.text.rectangle")
            }

            Divider()

            Button(action: onShowConfiguration) {
                Label("AI Configuration", systemImage: "gearshape")
            }

            Button(action: onExport) {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(exportDisabled)
        } label: {
            UserAvatar(profile: profileViewModel.profile, size: 34)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("Main menu")
    }
}
