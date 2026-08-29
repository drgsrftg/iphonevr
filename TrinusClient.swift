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
    private var sensorListener: NWListener?
    private var sensorConnection: NWConnection?

    private var running = false
    private var host = ""

    private var cy = 0.0
    private var cp = 0.0
    private var cr = 0.0

    private let videoPort: NWEndpoint.Port = 7777
    private let sensorPort: NWEndpoint.Port = 5555

    // UDP video protocol:
    // 2 bytes frame id + 1 byte total chunks + 1 byte chunk index + JPEG data
    private var chunks: [Int: [Int: Data]] = [:]
    private var chunkTotals: [Int: Int] = [:]
    private let videoLock = NSLock()
    private var newestFrameID = -1

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

    func stop() {
        stop(silent: false)
    }

    private func stop(silent: Bool) {
        running = false

        video?.cancel()
        sensorConnection?.cancel()
        sensorListener?.cancel()

        video = nil
        sensorConnection = nil
        sensorListener = nil

        videoLock.lock()
        chunks.removeAll()
        chunkTotals.removeAll()
        newestFrameID = -1
        videoLock.unlock()

        motion.stopDeviceMotionUpdates()

        if !silent {
            DispatchQueue.main.async {
                self.status = "Durduruldu"
            }
        }
    }

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
        guard running else { return }

        let bounds = UIScreen.main.bounds
        let width = max(bounds.width, bounds.height)
        let height = min(bounds.width, bounds.height)
        let scale = UIScreen.main.scale

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
            "stroverlay": "",
            "screenWidth": width * scale,
            "screenHeight": height * scale,
            "vrAspect": width / height
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings
            )

            video?.send(
                content: data,
                completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.failVideo(
                            "UDP handshake gönderilemedi: \(error.localizedDescription)"
                        )
                    }
                }
            )
        } catch {
            failVideo("UDP handshake hazırlanamadı")
        }
    }

    // Keep receiving every UDP datagram continuously.
    private func receiveUDP() {
        guard running, let video else { return }

        video.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.running else { return }

            if let error {
                self.failVideo(
                    "UDP alınamadı: \(error.localizedDescription)"
                )
                self.receiveUDP()
                return
            }

            if let data, !data.isEmpty {
                self.handleUDPDatagram(data)
            }

            self.receiveUDP()
        }
    }

    private func handleUDPDatagram(_ data: Data) {
        guard running else { return }

        // Handshake/settings packet, if any.
        if data.first == UInt8(ascii: "{") {
            return
        }

        // Minimum video header is 4 bytes.
        guard data.count >= 5 else { return }

        let frameID =
            (Int(data[0]) << 8) |
            Int(data[1])

        let total = Int(data[2])
        let index = Int(data[3])

        guard total > 0,
              total <= 255,
              index >= 0,
              index < total else {
            return
        }

        let payload = data.subdata(in: 4..<data.count)

        videoLock.lock()

        // A newer frame arrived. Old incomplete frames can be discarded.
        if frameID > newestFrameID {
            newestFrameID = frameID

            chunks = chunks.filter {
                $0.key >= frameID - 1
            }

            chunkTotals = chunkTotals.filter {
                $0.key >= frameID - 1
            }
        }

        if frameID < newestFrameID - 1 {
            videoLock.unlock()
            return
        }

        if chunks[frameID] == nil {
            chunks[frameID] = [:]
        }

        chunks[frameID]?[index] = payload
        chunkTotals[frameID] = total

        let received = chunks[frameID]?.count ?? 0
        let complete = received == total

        var frameData: Data?

        if complete,
           let frameChunks = chunks[frameID] {

            var combined = Data()

            for i in 0..<total {
                guard let part = frameChunks[i] else {
                    videoLock.unlock()
                    return
                }
                combined.append(part)
            }

            frameData = combined

            chunks.removeValue(forKey: frameID)
            chunkTotals.removeValue(forKey: frameID)
        }

        videoLock.unlock()

        guard let frameData else { return }

        // JPEG magic bytes check.
        guard frameData.count >= 4,
              frameData[0] == 0xFF,
              frameData[1] == 0xD8 else {
            return
        }

        guard let decoded = UIImage(data: frameData) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }

            self.image = decoded
            self.status = "iPhoneVR bağlı • görüntü + sensör"
        }
    }

    private func failVideo(_ message: String) {
        guard running else { return }

        DispatchQueue.main.async {
            self.status = message
        }
    }

    // =====================================================
    // SENSOR TCP 5555
    // =====================================================

    private func startSensorServer() {
        do {
            let listener = try NWListener(
                using: .tcp,
                on: sensorPort
            )

            sensorListener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        if self.running {
                            self.status = "Sensör portu 5555 hazır"
                        }

                    case .failed(let error):
                        if self.running {
                            self.status =
                                "Sensör portu hata: \(error.localizedDescription)"
                        }

                    default:
                        break
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
                            if self.running {
                                self.status = "Sensör bağlı"
                            }
                        }
                    }
                }

                connection.start(
                    queue: .global(qos: .userInteractive)
                )
            }

            listener.start(
                queue: .global(qos: .userInteractive)
            )

        } catch {
            status =
                "Sensör server başlatılamadı: \(error.localizedDescription)"
        }
    }

    // =====================================================
    // MOTION
    // =====================================================

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            DispatchQueue.main.async {
                self.status = "DeviceMotion kullanılamıyor"
            }
            return
        }

        motion.deviceMotionUpdateInterval = 1.0 / 60.0

        motion.startDeviceMotionUpdates(
            using: .xArbitraryCorrectedZVertical,
            to: OperationQueue()
        ) { [weak self] dm, error in

            guard let self,
                  let dm,
                  self.running,
                  error == nil else {
                return
            }

            let attitude = dm.attitude
            let q = attitude.quaternion

            let y = attitude.yaw - self.cy
            let p = attitude.pitch - self.cp
            let r = attitude.roll - self.cr

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
        guard running,
              sensorConnection != nil else {
            return
        }

        var packet = Data()
        packet.reserveCapacity(53)

        packet.append(0)
        packet.append(0)
        packet.append(0)
        packet.append(0)
        packet.append(0)

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

        sensorConnection?.send(
            content: packet,
            completion: .contentProcessed { _ in }
        )
    }

    private func appendFloatLE(
        _ data: inout Data,
        _ value: Float
    ) {
        var bits = value.bitPattern.littleEndian

        withUnsafeBytes(of: &bits) {
            data.append(contentsOf: $0)
        }
    }

    private func makeTrinusCode(
        ref: String,
        module: String
    ) -> String {
        let digest = Insecure.SHA1.hash(
            data: Data((ref + module).utf8)
        )

        return Data(digest).base64EncodedString() + module
    }

    func center() {
        guard let deviceMotion = motion.deviceMotion else {
            return
        }

        cy = deviceMotion.attitude.yaw
        cp = deviceMotion.attitude.pitch
        cr = deviceMotion.attitude.roll
    }
}
