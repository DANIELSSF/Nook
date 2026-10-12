import SwiftUI

struct CapturePrivacyPane: View {
    @ObservedObject var privacy: CapturePrivacy
    var onContentChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                SectionLabel("Capturas y pantalla compartida")
                Spacer(minLength: 0)
                Text("Experimental").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.nookAmber).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.nookAmberFill.opacity(0.14), in: Capsule())
            }
            Toggle("Excluir Nook de las capturas", isOn: $privacy.enabled)
                .toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12, weight: .medium))
                .disabled(!privacy.isAvailable && !privacy.enabled)
            Text("Mantiene Nook visible para ti e intenta excluir sus ventanas de capturas y grabaciones. El icono de la barra de menús se oculta mientras esté activo.")
            Text("Depende de macOS y de la app que comparte pantalla. Comprueba la vista de quien recibe en Meet o Discord antes de confiar en esta opción.")
            if let issue = privacy.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.nookAmber)
            } else if !privacy.isAvailable {
                Label("No disponible en esta versión de macOS.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.nookAmber)
            }
            Divider().overlay(Color.nookWash(0.08))
            Text("La terminal original, los diálogos del sistema y algunos menús pueden seguir apareciendo. Nook continúa visible en Monitor de Actividad y en las listas de procesos.")
            Text("Desactivado por defecto. Puedes seguir abriendo los ajustes desde el gatito.")
                .font(.system(size: 10))
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.nookSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: privacy.issue) { _, _ in onContentChange() }
    }
}
