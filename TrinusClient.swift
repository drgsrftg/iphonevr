import Foundation
import Network
import CoreMotion
import UIKit
import CryptoKit

final class TrinusClient: ObservableObject {
    @Published var image: UIImage?
    @Published var status = "Hazır"
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var roll = 0.0

    private let motion = CMMotionManager()
    private var video: NWConnection?
    private var sensor: NWConnection?
    private var videoBuffer = Data()
    private var settingsBuffer = Data()
    private var running = false
    private var host = ""

    private var cy = 0.0
    private var cp = 0.0
    private var cr = 0.0

    private let videoPort: NWEndpoint.Port = 7777
    private let sensorPort: NWEndpoint.Port = 5555

    func start(ip: String) {
        stop(silent: true)
        host = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { status = "PC IP adresi gerekli"; return }
        running = true
        status = "Trinus'a bağlanıyor..."
        connectVideo()
        connectSensor()
        startMotion()
    }

    func stop() { stop(silent: false) }

    private func stop(silent: Bool) {
        running = false
        video?.cancel(); sensor?.cancel()
        video = nil; sensor = nil
        videoBuffer.removeAll(keepingCapacity: false)
        settingsBuffer.removeAll(keepingCapacity: false)
        motion.stopDeviceMotionUpdates()
        if !silent { DispatchQueue.main.async { self.status = "Durduruldu" } }
    }

    func center() {
        guard let d = motion.deviceMotion else { return }
        cy = d.attitude.yaw; cp = d.attitude.pitch; cr = d.attitude.roll
    }

    private func connectVideo() {
        let c = NWConnection(host: NWEndpoint.Host(host), port: videoPort, using: .tcp)
        video = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.status = "Trinus 7777 bağlı"
                    self.readSettings()
                case .failed(let error):
                    self.status = "Trinus 7777 hata: \(error.localizedDescription)"
                default: break
                }
            }
        }
        c.start(queue: .global(qos: .userInteractive))
    }

    private func readSettings() {
        guard running, let video else { return }
        video.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.running else { return }
            if let data, !data.isEmpty {
                self.settingsBuffer.append(data)
                if let end = self.settingsBuffer.firstIndex(of: UInt8(ascii: "}")) {
                    let endExclusive = self.settingsBuffer.index(after: end)
                    let jsonData = self.settingsBuffer.subdata(in: 0..<endExclusive)
                    self.settingsBuffer.removeSubrange(0..<endExclusive)
                    self.handleSettings(jsonData)
                    return
                }
            }
            if isComplete { self.failVideo("Trinus settings bağlantısı kapandı") }
            else if error == nil { self.readSettings() }
            else { self.failVideo("Trinus settings alınamadı") }
        }
    }

    private func handleSettings(_ data: Data) {
        guard running else { return }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ref = obj["ref"] as? String else {
                failVideo("Trinus settings geçersiz"); return
            }

            let module = "_defaulttglibva"
            let settings: [String: Any] = [
                "version": "std2",
                "code": makeTrinusCode(ref: ref, module: module),
                "videostream": "mjpeg",
                "sensorstream": "normal",
                "sensorport": 5555,
                "sensorVersion": 1,
                "motionboost": false,
                "nolens": false,
                "convertimage": false,
                "fakeroll": false,
                "source": "None",
                "project": "iPhoneVR",
                "proc": "None",
                "stroverlay": ""
            ]

            let out = try JSONSerialization.data(withJSONObject: settings)
            video?.send(content: out, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { self.failVideo("Trinus handshake gönderilemedi: \(error.localizedDescription)"); return }
                DispatchQueue.main.async { self.status = "Trinus bağlı • görüntü bekleniyor" }
                self.readVideo()
                self.requestNextFrame()
            })
        } catch { failVideo("Trinus settings işlenemedi") }
    }

    private func requestNextFrame() {
        guard running else { return }
        video?.send(content: Data([0x65]), completion: .contentProcessed { [weak self] error in
            if let error { self?.failVideo("Frame isteği gönderilemedi: \(error.localizedDescription)") }
        })
    }

    private func readVideo() {
        guard running, let video else { return }
        video.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self, self.running else { return }
            if let data, !data.isEmpty { self.videoBuffer.append(data); self.decodeFrames() }
            if isComplete { self.failVideo("Trinus görüntü bağlantısı kapandı") }
            else if error == nil { self.readVideo() }
            else { self.failVideo("Trinus görüntü alınamadı") }
        }
    }

    private func decodeFrames() {
        while videoBuffer.count >= 4 {
            let n = Int(videoBuffer[0]) << 24 | Int(videoBuffer[1]) << 16 | Int(videoBuffer[2]) << 8 | Int(videoBuffer[3])
            guard n > 0, n <= 20_000_000 else { videoBuffer.removeAll(); return }
            guard videoBuffer.count >= n + 4 else { return }
            let frame = videoBuffer.subdata(in: 4..<(n + 4))
            videoBuffer.removeSubrange(0..<(n + 4))
            if let im = UIImage(data: frame) {
                DispatchQueue.main.async { self.image = im; self.status = "Trinus bağlı • görüntü + sensör" }
            }
            requestNextFrame()
        }
    }

    private func failVideo(_ message: String) {
        guard running else { return }
        DispatchQueue.main.async { self.status = message }
    }

    private func connectSensor() {
        let c = NWConnection(host: NWEndpoint.Host(host), port: sensorPort, using: .tcp)
        sensor = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                DispatchQueue.main.async { if self.running { self.status = "Trinus sensör bağlı" } }
            }
        }
        c.start(queue: .global(qos: .userInteractive))
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            DispatchQueue.main.async { self.status = "DeviceMotion kullanılamıyor" }; return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: OperationQueue()) { [weak self] dm, error in
            guard let self, let dm, self.running, error == nil else { return }
            let a = dm.attitude; let q = a.quaternion
            let y = a.yaw - self.cy; let p = a.pitch - self.cp; let r = a.roll - self.cr
            DispatchQueue.main.async {
                self.yaw = y * 180.0 / .pi; self.pitch = p * 180.0 / .pi; self.roll = r * 180.0 / .pi
            }
            self.sendSensor(yaw: y, pitch: p, roll: r, quaternion: q, accel: dm.userAcceleration)
        }
    }

    private func sendSensor(yaw: Double, pitch: Double, roll: Double, quaternion q: CMQuaternion, accel: CMAcceleration) {
        guard running else { return }
        var packet = Data(); packet.reserveCapacity(53)
        packet.append(0); packet.append(0); packet.append(0)
        packet.append(0); packet.append(0)
        appendFloatLE(&packet, 0); appendFloatLE(&packet, 0)
        appendFloatLE(&packet, Float(yaw)); appendFloatLE(&packet, Float(pitch)); appendFloatLE(&packet, Float(roll))
        appendFloatLE(&packet, Float(q.x)); appendFloatLE(&packet, Float(q.y)); appendFloatLE(&packet, Float(q.z)); appendFloatLE(&packet, Float(q.w))
        appendFloatLE(&packet, Float(accel.x)); appendFloatLE(&packet, Float(accel.y)); appendFloatLE(&packet, Float(accel.z))
        guard packet.count == 53 else { return }
        sensor?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func appendFloatLE(_ data: inout Data, _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private func makeTrinusCode(ref: String, module: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((ref + module).utf8))
        return Data(digest).base64EncodedString() + module
    }
}
