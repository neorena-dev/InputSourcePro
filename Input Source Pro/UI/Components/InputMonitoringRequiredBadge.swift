import SwiftUI

struct InputMonitoringRequiredBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .font(.system(size: 14, weight: .medium))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Input Monitoring Permission Required")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                
                Text("English punctuation forcing requires Input Monitoring permission to intercept keystrokes.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            Button("Grant Permission") {
                PermissionsVM.checkInputMonitoring(prompt: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    InputMonitoringRequiredBadge()
        .padding()
}