import socket
import struct
import threading
import time
import sys
import ctypes

import cv2
import mss
import numpy as np


# =========================================================
# iPhoneVR SERVER
# =========================================================
# UDP 7777 : video
# TCP 5555 : sensor connection back to iPhone
# Video packet: 4-byte big-endian JPEG size + JPEG
#
# Mouse mode:
#   Phone yaw   -> mouse X
#   Phone pitch -> mouse Y
#   No SteamVR required.
# =========================================================

HOST = "0.0.0.0"
VIDEO_PORT = 7777
SENSOR_PORT = 5555

CAPTURE_FPS = 30
JPEG_QUALITY = 45
MIN_JPEG_QUALITY = 20
MAX_UDP_SIZE = 60000

# Keep the complete PC screen in both eyes.
EYE_WIDTH = 540
EYE_HEIGHT = 500

# Mouse sensitivity. Increase/decrease if needed.
MOUSE_SENSITIVITY = 950.0
MOUSE_DEADZONE = 0.0008
MAX_MOUSE_STEP = 45


# =========================================================
# WINDOWS MOUSE
# =========================================================

mouse_enabled = sys.platform.startswith("win")

if mouse_enabled:
    class MOUSEINPUT(ctypes.Structure):
        _fields_ = [
            ("dx", ctypes.c_long),
            ("dy", ctypes.c_long),
            ("mouseData", ctypes.c_ulong),
            ("dwFlags", ctypes.c_ulong),
            ("time", ctypes.c_ulong),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class INPUT_UNION(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT)]

    class INPUT(ctypes.Structure):
        _anonymous_ = ("u",)
        _fields_ = [
            ("type", ctypes.c_ulong),
            ("u", INPUT_UNION),
        ]

    INPUT_MOUSE = 0
    MOUSEEVENTF_MOVE = 0x0001


def move_mouse(dx, dy):
    """Send a relative Windows mouse movement."""
    if not mouse_enabled:
        return

    dx = int(max(-MAX_MOUSE_STEP, min(MAX_MOUSE_STEP, dx)))
    dy = int(max(-MAX_MOUSE_STEP, min(MAX_MOUSE_STEP, dy)))

    if dx == 0 and dy == 0:
        return

    inp = INPUT(
        type=INPUT_MOUSE,
        mi=MOUSEINPUT(
            dx=dx,
            dy=dy,
            mouseData=0,
            dwFlags=MOUSEEVENTF_MOVE,
            time=0,
            dwExtraInfo=None,
        ),
    )

    ctypes.windll.user32.SendInput(
        1,
        ctypes.byref(inp),
        ctypes.sizeof(INPUT),
    )


# =========================================================
# SCREEN CAPTURE
# =========================================================

sct = mss.mss()
monitor = sct.monitors[1]

latest_frame = None
frame_lock = threading.Lock()
capture_running = True


def encode_frame(frame):
    """Resize complete PC screen and duplicate it side-by-side."""
    eye = cv2.resize(
        frame,
        (EYE_WIDTH, EYE_HEIGHT),
        interpolation=cv2.INTER_AREA,
    )

    stereo = np.concatenate((eye, eye), axis=1)

    quality = JPEG_QUALITY

    while quality >= MIN_JPEG_QUALITY:
        ok, result = cv2.imencode(
            ".jpg",
            stereo,
            [cv2.IMWRITE_JPEG_QUALITY, quality],
        )

        if not ok:
            return None

        data = result.tobytes()

        if len(data) + 4 <= MAX_UDP_SIZE:
            return data

        quality -= 5

    return None


def capture_loop():
    global latest_frame

    interval = 1.0 / CAPTURE_FPS

    print(f"[VIDEO] Ekran yakalama: {CAPTURE_FPS} FPS")
    print(
        f"[VIDEO] Stereo frame: "
        f"{EYE_WIDTH}x{EYE_HEIGHT} + {EYE_WIDTH}x{EYE_HEIGHT}"
    )
    print("[VIDEO] Crop yok - PC ekranı iki göze gönderiliyor")

    while capture_running:
        started = time.perf_counter()

        try:
            grabbed = sct.grab(monitor)
            frame = np.asarray(grabbed)
            frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)

            encoded = encode_frame(frame)

            if encoded is not None:
                with frame_lock:
                    latest_frame = encoded

        except Exception as exc:
            print(f"\n[VIDEO] Capture hatası: {exc}")

        elapsed = time.perf_counter() - started
        remaining = interval - elapsed
        if remaining > 0:
            time.sleep(remaining)


# =========================================================
# SENSOR TCP 5555
# =========================================================

sensor_socket = None
sensor_lock = threading.Lock()
sensor_buffer = bytearray()

# Previous sensor values for relative mouse movement.
last_yaw = None
last_pitch = None
mouse_lock = threading.Lock()


def reset_mouse_reference():
    global last_yaw, last_pitch
    with mouse_lock:
        last_yaw = None
        last_pitch = None


def update_mouse(yaw, pitch):
    """Convert phone yaw/pitch changes into relative mouse movement."""
    global last_yaw, last_pitch

    with mouse_lock:
        if last_yaw is None or last_pitch is None:
            last_yaw = yaw
            last_pitch = pitch
            return

        dyaw = yaw - last_yaw
        dpitch = pitch - last_pitch

        # Handle wraparound at +/- pi for yaw.
        if dyaw > np.pi:
            dyaw -= 2.0 * np.pi
        elif dyaw < -np.pi:
            dyaw += 2.0 * np.pi

        last_yaw = yaw
        last_pitch = pitch

    if abs(dyaw) < MOUSE_DEADZONE:
        dx = 0
    else:
        # Yaw direction was reversed, so invert X.
        dx = round(-dyaw * MOUSE_SENSITIVITY)

    if abs(dpitch) < MOUSE_DEADZONE:
        dy = 0
    else:
        # Pitch directly controls vertical mouse movement.
        dy = round(dpitch * MOUSE_SENSITIVITY)

    move_mouse(dx, dy)


def sensor_connect(phone_ip):
    global sensor_socket

    with sensor_lock:
        if sensor_socket is not None:
            return

    print(f"[SENSOR] {phone_ip}:5555 bağlantısı deneniyor...")

    while capture_running:
        sock = None

        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((phone_ip, SENSOR_PORT))
            sock.settimeout(None)

            with sensor_lock:
                sensor_socket = sock

            reset_mouse_reference()

            print("[SENSOR] iPhone TCP 5555 bağlandı")
            if mouse_enabled:
                print("[MOUSE] Telefon hareketi -> Windows mouse aktif")
            else:
                print("[MOUSE] Windows dışında çalışıyor; mouse devre dışı")

            receive_sensor(sock)
            return

        except Exception as exc:
            print(f"[SENSOR] Bağlantı başarısız: {exc}")

            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass

            time.sleep(2)


def receive_sensor(sock):
    global sensor_socket

    sensor_buffer.clear()

    while capture_running:
        try:
            data = sock.recv(4096)

            if not data:
                print("\n[SENSOR] iPhone bağlantısı kapandı")
                break

            sensor_buffer.extend(data)

            while len(sensor_buffer) >= 53:
                packet = bytes(sensor_buffer[:53])
                del sensor_buffer[:53]
                parse_sensor(packet)

        except Exception as exc:
            print(f"\n[SENSOR] Okuma hatası: {exc}")
            break

    with sensor_lock:
        if sensor_socket is sock:
            sensor_socket = None

    reset_mouse_reference()

    try:
        sock.close()
    except OSError:
        pass


def parse_sensor(data):
    if len(data) != 53:
        return

    try:
        yaw, pitch, roll = struct.unpack("<3f", data[13:25])
        qx, qy, qz, qw = struct.unpack("<4f", data[25:41])

        # Mouse control uses RELATIVE yaw/pitch changes.
        update_mouse(yaw, pitch)

        print(
            "\r"
            f"[SENSOR] Yaw: {yaw:+.3f}  "
            f"Pitch: {pitch:+.3f}  "
            f"Roll: {roll:+.3f}  "
            f"Q: {qx:+.2f},{qy:+.2f},{qz:+.2f},{qw:+.2f}",
            end="",
            flush=True,
        )

    except Exception as exc:
        print(f"\n[SENSOR] Parse hatası: {exc}")


# =========================================================
# VIDEO UDP 7777
# =========================================================

class VideoServer:
    def __init__(self):
        self.running = True
        self.phone_addr = None

        self.sock = socket.socket(
            socket.AF_INET,
            socket.SOCK_DGRAM,
        )

        self.sock.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_REUSEADDR,
            1,
        )

        self.sock.bind((HOST, VIDEO_PORT))

        print(f"[VIDEO] UDP {VIDEO_PORT} dinleniyor")

    def send_frame(self):
        if self.phone_addr is None:
            return

        with frame_lock:
            jpeg = latest_frame

        if jpeg is None:
            return

        packet = struct.pack(">I", len(jpeg)) + jpeg

        if len(packet) > 65507:
            print(f"\n[VIDEO] Frame fazla büyük: {len(packet)} byte")
            return

        try:
            self.sock.sendto(packet, self.phone_addr)
        except OSError as exc:
            if self.running:
                print(f"\n[VIDEO] UDP gönderme hatası: {exc}")

    def run(self):
        while self.running:
            try:
                data, addr = self.sock.recvfrom(65535)
            except OSError:
                break

            if not data:
                continue

            if self.phone_addr != addr:
                self.phone_addr = addr

                print(
                    f"[VIDEO] iPhone bulundu: "
                    f"{addr[0]}:{addr[1]}"
                )

                threading.Thread(
                    target=sensor_connect,
                    args=(addr[0],),
                    daemon=True,
                ).start()

            if data.startswith(b"{"):
                print("[VIDEO] iPhone handshake aldı")
                continue

            # Client requests exactly one frame with byte 'e'.
            if data == b"e":
                self.send_frame()

    def close(self):
        self.running = False

        try:
            self.sock.close()
        except OSError:
            pass


# =========================================================
# MAIN
# =========================================================

def main():
    global capture_running

    print()
    print("======================================")
    print("              iPhoneVR")
    print("======================================")
    print()
    print(f"VIDEO       : UDP {VIDEO_PORT}")
    print(f"SENSOR      : TCP {SENSOR_PORT}")
    print(f"CAPTURE FPS : {CAPTURE_FPS}")
    print(f"JPEG        : {JPEG_QUALITY}")
    print(f"EYE         : {EYE_WIDTH}x{EYE_HEIGHT}")
    print(f"MOUSE       : {'AKTİF' if mouse_enabled else 'KAPALI'}")
    print(f"MOUSE SENS  : {MOUSE_SENSITIVITY}")
    print("STEREO      : Aynı PC görüntüsü iki göze")
    print("CROP        : YOK")
    print()
    print("Telefon bekleniyor...")
    print()

    threading.Thread(
        target=capture_loop,
        daemon=True,
    ).start()

    video = VideoServer()

    try:
        video.run()

    except KeyboardInterrupt:
        print("\n\nServer kapatılıyor...")

    finally:
        capture_running = False
        video.close()

        with sensor_lock:
            sock = sensor_socket

            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass

        print("\nServer kapandı.")


if __name__ == "__main__":
    main()
