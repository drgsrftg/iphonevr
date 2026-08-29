import SwiftUI
import CoreMotion
import Network
import WebKit

final class MotionManager: ObservableObject {
    private let motion = CMMotionManager()
    private var connection: NWConnection?
    private var timer: Timer?
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var roll = 0.0
    @Published var connected = false

    private let gyroPort: NWEndpoint.Port = 1533

    func start(ip: String) {
        stop()
        connection = NWConnection(host: NWEndpoint.Host(ip), port: gyroPort, using: .udp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.connected = state == .ready }
        }
        connection?.start(queue: .global(qos: .userInteractive))
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let d = self.motion.deviceMotion else { return }
            let q = d.attitude.quaternion
            let yaw = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z)) * 180 / .pi
            let pitch = asin(max(-1, min(1, 2 * (q.w * q.y - q.z * q.x)))) * 180 / .pi
            let roll = atan2(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y)) * 180 / .pi
            DispatchQueue.main.async {
                self.yaw = yaw
                self.pitch = pitch
                self.roll = roll
            }
            let packet = String(format: "%.3f,%.3f,%.3f", yaw, pitch, roll)
            self.connection?.send(content: packet.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        motion.stopDeviceMotionUpdates()
        connection?.cancel(); connection = nil
        connected = false
    }
}

struct StreamView: UIViewRepresentable {
    let ip: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.loadHTMLString(html, baseURL: URL(string: "http://\(ip):5000/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private var html: String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}
        #vr{display:flex;flex-direction:row;width:100vw;height:100vh}
        .eye{width:50vw;height:100vh;overflow:hidden}
        img{display:block;width:100%;height:100%;object-fit:fill}
        </style></head><body><div id="vr">
        <div class="eye"><img src="/stream"></div>
        <div class="eye"><img src="/stream"></div>
        </div></body></html>
        """
    }
}

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @State private var ip = "192.168.1.131"
    @State private var running = false
    @State private var showSetup = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showSetup {
                VStack(spacing: 18) {
                    Text("iPhone VR").font(.largeTitle.bold())
                    Text("PC görüntüsü + iPhone gyro").foregroundStyle(.secondary)
                    TextField("PC IP adresi", text: $ip)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(maxWidth: 300)
                    Text(motion.connected ? "● GYRO BAĞLI • UDP 1533" : "○ GYRO BEKLENİYOR • UDP 1533")
                        .foregroundStyle(motion.connected ? .green : .orange)
                    Button("VR'YI BAŞLAT") {
                        motion.start(ip: ip)
                        running = true
                        showSetup = false
                    }.buttonStyle(.borderedProminent)
                }.padding()
            } else {
                StreamView(ip: ip).ignoresSafeArea()
                VStack {
                    HStack {
                        Spacer()
                        Button("×") {
                            motion.stop(); running = false; showSetup = true
                        }
                        .font(.title2.bold())
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55))
                        .clipShape(Circle())
                        .foregroundStyle(.white)
                        .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .statusBarHidden(true)
        .onDisappear { motion.stop() }
    }
}
