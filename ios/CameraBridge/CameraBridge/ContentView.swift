import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()

    var body: some View {
        VStack(spacing: 16) {
            // Connection status + auto count
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                Text(ble.connectionState.rawValue)
                    .font(.headline)
                Spacer()
                if ble.autoSnapshotCount > 0 {
                    Text("Auto: \(ble.autoSnapshotCount)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(8)
                }
                if ble.uploadState != .idle {
                    uploadBadge
                }
            }
            .padding(.top)
            .padding(.horizontal)

            // Snapshot image (show annotated version if available)
            if let image = ble.faceRecognition.processedImage ?? ble.snapshotImage {
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

            // Recognized faces
            if !ble.faceRecognition.recognizedNames.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundColor(.green)
                    Text(ble.faceRecognition.recognizedNames.joined(separator: ", "))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.15))
                .cornerRadius(8)
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

    private var uploadBadge: some View {
        HStack(spacing: 4) {
            if ble.uploadState == .uploading {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Text(ble.uploadState.rawValue)
                .font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(uploadBadgeColor.opacity(0.2))
        .cornerRadius(8)
    }

    private var uploadBadgeColor: Color {
        switch ble.uploadState {
        case .uploading: return .blue
        case .success:   return .green
        case .failed:    return .red
        case .idle:      return .clear
        }
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
