import SwiftUI
import CoreMotion
import Network

final class MotionManager: ObservableObject {
    private let motion = CMMotionManager()
    private var connection: NWConnection?
    private var timer: Timer?
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var roll = 0.0
    @Published var connected = false

    func start(ip: String) {
        stop()
        guard let port = NWEndpoint.Port(rawValue: 8766) else { return }
        connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .udp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.connected = state == .ready }
        }
        connection?.start(queue: .global(qos: .userInteractive))
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        guard motion.isDeviceMotionAvailable else { return }
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let d = self.motion.deviceMotion else { return }
            let a = d.attitude
            let q = a.quaternion
            let yaw = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z)) * 180 / .pi
            let pitch = asin(max(-1, min(1, 2 * (q.w * q.y - q.z * q.x)))) * 180 / .pi
            let roll = atan2(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y)) * 180 / .pi
            DispatchQueue.main.async {
                self.yaw = yaw
                self.pitch = pitch
                self.roll = roll
            }
            let text = String(format: "{\"type\":\"gyro\",\"yaw\":%.3f,\"pitch\":%.3f,\"roll\":%.3f}", yaw, pitch, roll)
            self.connection?.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        motion.stopDeviceMotionUpdates()
        connection?.cancel()
        connection = nil
        connected = false
    }
}

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @State private var ip = "192.168.1.131"
    @State private var running = false

    var body: some View {
        VStack(spacing: 20) {
            Text("iPhone VR").font(.largeTitle.bold())
            Text(motion.connected ? "● PC BAĞLI" : "○ PC BAĞLI DEĞİL")
                .foregroundStyle(motion.connected ? .green : .secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "Yaw    %8.2f°", motion.yaw))
                Text(String(format: "Pitch  %8.2f°", motion.pitch))
                Text(String(format: "Roll   %8.2f°", motion.roll))
            }
            .font(.system(.title3, design: .monospaced))
            TextField("PC IP adresi", text: $ip)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
            Button(running ? "DURDUR" : "BAŞLAT") {
                if running { motion.stop() } else { motion.start(ip: ip) }
                running.toggle()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .onDisappear { motion.stop() }
    }
}
