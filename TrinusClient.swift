import Foundation
import Network
import CoreMotion
import UIKit

final class TrinusClient: ObservableObject {
    @Published var image: UIImage?
    @Published var status = "Hazır"
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var roll = 0.0

    private let motion = CMMotionManager()
    private var video: NWConnection?
    private var sensor: NWConnection?
    private var buffer = Data()
    private var running = false
    private var host = ""
    private var cy = 0.0
    private var cp = 0.0
    private var cr = 0.0

    func start(ip: String) {
        stop()
        host = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        running = true
        status = "Trinus'a bağlanıyor..."
        connectVideo()
        connectSensor()
        startMotion()
    }

    func stop() {
        running = false
        video?.cancel(); video = nil
        sensor?.cancel(); sensor = nil
        buffer.removeAll()
        motion.stopDeviceMotionUpdates()
        DispatchQueue.main.async { self.status = "Durduruldu" }
    }

    func center() {
        guard let d = motion.deviceMotion else { return }
        cy = d.attitude.yaw
        cp = d.attitude.pitch
        cr = d.attitude.roll
    }

    private func connectVideo() {
        guard let port = NWEndpoint.Port(rawValue: 7777) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        video = c
        c.stateUpdateHandler = { [weak self] s in
            DispatchQueue.main.async {
                if case .ready = s {
                    self?.status = "Trinus görüntü bağlı"
                    self?.readSettings()
                }
                if case .failed = s {
                    self?.status = "Trinus 7777 bağlantısı başarısız"
                }
            }
        }
        c.start(queue: .global(qos: .userInteractive))
    }

    private func readSettings() {
        video?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, self.running else { return }
            if let data, !data.isEmpty { self.sendSettings() }
            if error == nil { self.readVideo() }
        }
    }

    private func sendSettings() {
        let obj: [String: Any] = [
            "version": "std2", "videostream": "mjpeg", "sensorstream": "normal",
            "sensorport": 5555, "sensorVersion": 1, "motionboost": false,
            "nolens": false, "convertimage": false, "fakeroll": false,
            "source": "None", "project": "iPhoneVR", "proc": "None", "stroverlay": ""
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        video?.send(content: d, completion: .contentProcessed { _ in })
    }

    private func readVideo() {
        video?.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, _, error in
            guard let self, self.running else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.decodeFrames()
            }
            if error == nil { self.readVideo() }
        }
    }

    private func decodeFrames() {
        while buffer.count >= 4 {
            let n = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard n > 0 && n < 20_000_000 else {
                buffer.removeAll()
                return
            }
            guard buffer.count >= n + 4 else { return }
            let d = buffer.subdata(in: 4..<(n + 4))
            buffer.removeSubrange(0..<(n + 4))
            if let im = UIImage(data: d) {
                DispatchQueue.main.async { self.image = im }
            }
        }
    }

    private func connectSensor() {
        guard let port = NWEndpoint.Port(rawValue: 5555) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        sensor = c
        c.stateUpdateHandler = { [weak self] s in
            if case .ready = s {
                DispatchQueue.main.async {
                    self?.status = "Trinus bağlı • görüntü + sensör"
                }
            }
        }
        c.start(queue: .global(qos: .userInteractive))
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: OperationQueue()) { [weak self] d, _ in
            guard let self, let d, self.running else { return }

            let a = d.attitude
            let q = a.quaternion
            let y = a.yaw - self.cy
            let p = a.pitch - self.cp
            let r = a.roll - self.cr

            DispatchQueue.main.async {
                self.yaw = y * 180 / .pi
                self.pitch = p * 180 / .pi
                self.roll = r * 180 / .pi
            }

            self.sendSensor(
                y: y,
                p: p,
                r: r,
                q: q,
                rotationRate: d.rotationRate
            )
        }
    }

    private func sendSensor(
        y: Double,
        p: Double,
        r: Double,
        q: CMQuaternion,
        rotationRate: CMRotationRate
    ) {
        var d = Data(repeating: 0, count: 5)

        appendFloat(&d, Float(0))
        appendFloat(&d, Float(0))
        appendFloat(&d, Float(y))
        appendFloat(&d, Float(p))
        appendFloat(&d, Float(r))
        appendFloat(&d, Float(q.x))
        appendFloat(&d, Float(q.y))
        appendFloat(&d, Float(q.z))
        appendFloat(&d, Float(q.w))

        // rotationRate CMAttitude'ta değil, CMDeviceMotion'dadır.
        appendFloat(&d, Float(rotationRate.x))
        appendFloat(&d, Float(rotationRate.y))
        appendFloat(&d, Float(rotationRate.z))

        sensor?.send(content: d, completion: .contentProcessed { _ in })
    }

    private func appendFloat(_ d: inout Data, _ x: Float) {
        var v = x
        withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
    }
}
