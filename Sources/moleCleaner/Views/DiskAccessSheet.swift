import SwiftUI

/// Popup du lancement quand l'accès complet au disque n'est pas accordé.
struct DiskAccessSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Brand.gradient).frame(width: 52, height: 52)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accès complet au disque").font(.title3.weight(.semibold))
                    Text("Certaines commandes de Mole doivent lire des dossiers protégés par macOS, comme les caches et journaux système ou les données des autres apps. Sans cet accès, elles en ignorent une partie.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Label("Dans Réglages Système › Confidentialité et sécurité › Accès complet au disque, active moleCleaner. S'il n'est pas dans la liste, ajoute-le avec le bouton +.",
                      systemImage: "info.circle")
                Label("Tu pourras changer d'avis dans les réglages de moleCleaner.", systemImage: "gearshape")
                Divider()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Refuser") {
                    model.diskAccess.decline()
                    dismiss()
                }
                Spacer()
                Button("Ouvrir les réglages") {
                    model.diskAccess.openSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}
