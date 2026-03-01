import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()

    var body: some View {
        VStack(spacing: 16) {
            // Connection status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                Text(ble.connectionState.rawValue)
                    .font(.headline)
            }
            .padding(.top)

            // Snapshot image
            if let image = ble.snapshotImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(12)
                    .padding(.horizontal)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .aspectRatio(4/3, contentMode: .fit)
                    .overlay(
                        Text("No snapshot yet")
                            .foregroundColor(.secondary)
                    )
                    .padding(.horizontal)
            }

            // Progress bar (visible during transfer)
            if ble.progress > 0 && ble.progress < 1.0 {
                ProgressView(value: ble.progress)
                    .padding(.horizontal)
            }

            // Transfer info
            if !ble.lastTransferInfo.isEmpty {
                Text(ble.lastTransferInfo)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 20) {
                Button(action: { ble.requestSnapshot() }) {
                    Label("Snapshot", systemImage: "camera.fill")
                        .font(.title3)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(!isReady)

                Button(action: {
                    if ble.connectionState == .disconnected {
                        ble.startScan()
                    } else {
                        ble.disconnect()
                    }
                }) {
                    Label(
                        ble.connectionState == .disconnected ? "Connect" : "Disconnect",
                        systemImage: ble.connectionState == .disconnected
                            ? "antenna.radiowaves.left.and.right"
                            : "xmark.circle"
                    )
                    .font(.title3)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(ble.connectionState == .disconnected ? Color.green : Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var isReady: Bool {
        ble.connectionState == .ready
    }

    private var statusColor: Color {
        switch ble.connectionState {
        case .ready:        return .green
        case .scanning, .connecting: return .orange
        case .capturing, .receiving: return .blue
        case .error:        return .red
        case .disconnected: return .gray
        }
    }
}

#Preview {
    ContentView()
}
