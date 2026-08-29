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
    private var sensorListener: NWListener?
    private var sensorConnection: NWConnection?
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
        guard !host.isEmpty else {
            status = "PC IP adresi gerekli"
            return
        }
        running = true
        status = "iPhoneVR UDP'ye bağlanıyor..."
        connectVideoUDP()
        startSensorServer()
        startMotion()
    }

    func stop() { stop(silent: false) }

    private func stop(silent: Bool) {
        running = false
        video?.cancel()
        sensorConnection?.cancel()
        sensorListener?.cancel()
        video = nil
        sensorConnection = nil
        sensorListener = nil
        motion.stopDeviceMotionUpdates()
        if !silent {
            DispatchQueue.main.async { self.status = "Durduruldu" }
        }
    }

    // =====================================================
    // UDP VIDEO 7777
    // Server packet = 4-byte big-endian JPEG length + JPEG.
    // One complete JPEG is sent in every UDP datagram.
    // =====================================================

    private func connectVideoUDP() {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: videoPort,
            using: .udp
        )
        video = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.status = "iPhoneVR UDP 7777 hazır"
                    self.sendUDPSettings()
                    self.requestFrame()
                case .failed(let error):
                    self.status = "UDP hata: \(error.localizedDescription)"
                case .waiting(let error):
                    self.status = "UDP bekleniyor: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
        receiveUDP()
    }

    private func sendUDPSettings() {
        let settings: [String: Any] = [
            "version": "std2",
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

        do {
            let data = try JSONSerialization.data(withJSONObject: settings)
            video?.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.failVideo("UDP handshake gönderilemedi: \(error.localizedDescription)")
                }
            })
        } catch {
            failVideo("UDP handshake hazırlanamadı")
        }
    }

    private func requestFrame() {
        guard running else { return }
        video?.send(content: Data([0x65]), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.failVideo("Frame isteği gönderilemedi: \(error.localizedDescription)")
            }
        })
    }

    private func receiveUDP() {
        guard running, let video else { return }

        video.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.running else { return }

            if let error {
                self.failVideo("UDP alınamadı: \(error.localizedDescription)")
            } else if let data, !data.isEmpty {
                self.handleVideoDatagram(data)
            }

            // Re-arm immediately so every frame is received.
            self.receiveUDP()
        }
    }

    private func handleVideoDatagram(_ data: Data) {
        // JSON is only handshake/control data.
        if data.first == UInt8(ascii: "{") {
            return
        }

        guard data.count >= 5 else { return }

        let jpegLength =
            (Int(data[0]) << 24) |
            (Int(data[1]) << 16) |
            (Int(data[2]) << 8) |
            Int(data[3])

        guard jpegLength > 0,
              jpegLength <= data.count - 4 else {
            return
        }

        let jpeg = data.subdata(in: 4..<(4 + jpegLength))

        guard jpeg.count >= 4,
              jpeg[0] == 0xFF,
              jpeg[1] == 0xD8 else {
            return
        }

        guard let decoded = UIImage(data: jpeg) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.image = decoded
            self.status = "iPhoneVR bağlı • görüntü + sensör"
        }

        requestFrame()
    }

    private func failVideo(_ message: String) {
        guard running else { return }
        DispatchQueue.main.async { self.status = message }
    }

    // =====================================================
    // SENSOR TCP 5555
    // =====================================================

    private func startSensorServer() {
        do {
            let listener = try NWListener(using: .tcp, on: sensorPort)
            sensorListener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    DispatchQueue.main.async {
                        if self.running {
                            self.status = "Sensör portu hata: \(error.localizedDescription)"
                        }
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.running else {
                    connection.cancel()
                    return
                }

                self.sensorConnection?.cancel()
                self.sensorConnection = connection

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .ready = state {
                        DispatchQueue.main.async {
                            if self.running { self.status = "Sensör bağlı" }
                        }
                    }
                }

                connection.start(queue: .global(qos: .userInteractive))
            }

            listener.start(queue: .global(qos: .userInteractive))
        } catch {
            status = "Sensör server başlatılamadı: \(error.localizedDescription)"
        }
    }

    // =====================================================
    // MOTION
    // =====================================================

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            DispatchQueue.main.async { self.status = "DeviceMotion kullanılamıyor" }
            return
        }

        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical,
            to: OperationQueue()
        ) { [weak self] dm, error in
            guard let self, let dm, self.running, error == nil else { return }

            let a = dm.attitude
            let q = a.quaternion
            let y = a.yaw - self.cy
            let p = a.pitch - self.cp
            let r = a.roll - self.cr

            DispatchQueue.main.async {
                self.yaw = y * 180.0 / .pi
                self.pitch = p * 180.0 / .pi
                self.roll = r * 180.0 / .pi
            }

            self.sendSensor(
                yaw: y,
                pitch: p,
                roll: r,
                quaternion: q,
                accel: dm.userAcceleration
            )
        }
    }

    private func sendSensor(
        yaw: Double,
        pitch: Double,
        roll: Double,
        quaternion q: CMQuaternion,
        accel: CMAcceleration
    ) {
        guard running, sensorConnection != nil else { return }

        var packet = Data()
        packet.reserveCapacity(53)

        packet.append(contentsOf: [0, 0, 0, 0, 0])
        appendFloatLE(&packet, 0)
        appendFloatLE(&packet, 0)
        appendFloatLE(&packet, Float(yaw))
        appendFloatLE(&packet, Float(pitch))
        appendFloatLE(&packet, Float(roll))
        appendFloatLE(&packet, Float(q.x))
        appendFloatLE(&packet, Float(q.y))
        appendFloatLE(&packet, Float(q.z))
        appendFloatLE(&packet, Float(q.w))
        appendFloatLE(&packet, Float(accel.x))
        appendFloatLE(&packet, Float(accel.y))
        appendFloatLE(&packet, Float(accel.z))

        guard packet.count == 53 else { return }
        sensorConnection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func appendFloatLE(_ data: inout Data, _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    func center() {
        guard let d = motion.deviceMotion else { return }
        cy = d.attitude.yaw
        cp = d.attitude.pitch
        cr = d.attitude.roll
    }
}
