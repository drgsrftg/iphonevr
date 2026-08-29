#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
#include <cmath>
#include <cstring>
#include <mutex>
#include <cstdio>
#include "openvr_driver.h"

#pragma comment(lib, "Ws2_32.lib")

static constexpr unsigned short DRIVER_PORT = 8767;
static constexpr float PI = 3.14159265358979323846f;

class IPhoneVRHMD final : public vr::ITrackedDeviceServerDriver {
public:
    vr::EVRInitError Activate(uint32_t id) override {
        objectId = id;
        auto props = vr::VRProperties();
        container = props->TrackedDeviceToPropertyContainer(id);

        props->SetStringProperty(container, vr::Prop_TrackingSystemName_String, "iPhoneVR");
        props->SetStringProperty(container, vr::Prop_ModelNumber_String, "iPhoneVR");
        props->SetStringProperty(container, vr::Prop_SerialNumber_String, "iPhoneVR-001");
        props->SetBoolProperty(container, vr::Prop_WillDriftInYaw_Bool, false);
        props->SetBoolProperty(container, vr::Prop_DeviceIsWireless_Bool, true);
        props->SetFloatProperty(container, vr::Prop_UserIpdMeters_Float, 0.063f);
        return vr::VRInitError_None;
    }

    void Deactivate() override {
        objectId = vr::k_unTrackedDeviceIndexInvalid;
    }

    void EnterStandby() override {}
    void* GetComponent(const char*) override { return nullptr; }

    void DebugRequest(const char*, char* response, uint32_t size) override {
        if (size > 0) response[0] = '\0';
    }

    vr::DriverPose_t GetPose() {
        std::lock_guard<std::mutex> lock(mutex);

        vr::DriverPose_t pose{};
        pose.poseTimeOffset = 0.0;
        pose.qWorldFromDriverRotation = {1, 0, 0, 0};
        pose.qDriverFromHeadRotation = {1, 0, 0, 0};
        pose.qRotation = rotation;
        pose.vecWorldFromDriverTranslation[0] = 0;
        pose.vecWorldFromDriverTranslation[1] = 0;
        pose.vecWorldFromDriverTranslation[2] = 0;
        pose.vecDriverFromHeadTranslation[0] = 0;
        pose.vecDriverFromHeadTranslation[1] = 0;
        pose.vecDriverFromHeadTranslation[2] = 0;
        pose.vecVelocity[0] = pose.vecVelocity[1] = pose.vecVelocity[2] = 0;
        pose.vecAngularVelocity[0] = pose.vecAngularVelocity[1] = pose.vecAngularVelocity[2] = 0;
        pose.result = vr::TrackingResult_Running_OK;
        pose.poseIsValid = true;
        pose.deviceIsConnected = true;
        pose.willDriftInYaw = false;
        pose.shouldApplyHeadModel = false;
        return pose;
    }

    void SetAngles(float yawDeg, float pitchDeg, float rollDeg) {
        const float yaw = yawDeg * PI / 180.0f;
        const float pitch = pitchDeg * PI / 180.0f;
        const float roll = rollDeg * PI / 180.0f;

        const float cy = cosf(yaw * 0.5f);
        const float sy = sinf(yaw * 0.5f);
        const float cp = cosf(pitch * 0.5f);
        const float sp = sinf(pitch * 0.5f);
        const float cr = cosf(roll * 0.5f);
        const float sr = sinf(roll * 0.5f);

        vr::HmdQuaternion_t q{};
        q.w = cr * cp * cy + sr * sp * sy;
        q.x = sr * cp * cy - cr * sp * sy;
        q.y = cr * sp * cy + sr * cp * sy;
        q.z = cr * cp * sy - sr * sp * cy;

        std::lock_guard<std::mutex> lock(mutex);
        rotation = q;
    }

    vr::TrackedDeviceIndex_t ObjectId() const { return objectId; }

private:
    vr::TrackedDeviceIndex_t objectId = vr::k_unTrackedDeviceIndexInvalid;
    vr::PropertyContainerHandle_t container = vr::k_ulInvalidPropertyContainer;
    vr::HmdQuaternion_t rotation{1, 0, 0, 0};
    mutable std::mutex mutex;
};

class IPhoneVRProvider final : public vr::IServerTrackedDeviceProvider {
public:
    vr::EVRInitError Init(vr::IVRDriverContext* context) override {
        VR_INIT_SERVER_DRIVER_CONTEXT(context);

        // The HMD must be able to initialize even when the UDP port is busy.
        // UDP is optional at startup; SteamVR should never fail initialization
        // merely because another process owns port 8767.
        WSAStartup(MAKEWORD(2, 2), &wsa);
        wsaStarted = true;

        hmd = new IPhoneVRHMD();

        if (!vr::VRServerDriverHost()->TrackedDeviceAdded(
                "iPhoneVR-HMD",
                vr::TrackedDeviceClass_HMD,
                hmd)) {
            delete hmd;
            hmd = nullptr;
            return vr::VRInitError_Driver_Failed;
        }

        // Try to open the gyro socket after registering the HMD.
        // Failure here is non-fatal: the HMD remains available.
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock != INVALID_SOCKET) {
            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            addr.sin_port = htons(DRIVER_PORT);

            if (bind(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
                closesocket(sock);
                sock = INVALID_SOCKET;
            } else {
                u_long mode = 1;
                ioctlsocket(sock, FIONBIO, &mode);
            }
        }

        return vr::VRInitError_None;
    }

    void Cleanup() override {
        if (sock != INVALID_SOCKET) {
            closesocket(sock);
            sock = INVALID_SOCKET;
        }

        delete hmd;
        hmd = nullptr;

        if (wsaStarted) {
            WSACleanup();
            wsaStarted = false;
        }

        VR_CLEANUP_SERVER_DRIVER_CONTEXT();
    }

    const char* const* GetInterfaceVersions() override {
        return vr::k_InterfaceVersions;
    }

    void RunFrame() override {
        if (sock == INVALID_SOCKET || hmd == nullptr)
            return;

        char buffer[256];
        sockaddr_in from{};
        int fromLen = sizeof(from);

        for (;;) {
            int count = recvfrom(
                sock,
                buffer,
                sizeof(buffer) - 1,
                0,
                reinterpret_cast<sockaddr*>(&from),
                &fromLen);

            if (count <= 0)
                break;

            buffer[count] = '\0';

            float yaw = 0.0f, pitch = 0.0f, roll = 0.0f;
            if (sscanf_s(buffer, "%f,%f,%f", &yaw, &pitch, &roll) != 3)
                continue;

            hmd->SetAngles(yaw, pitch, roll);

            const auto id = hmd->ObjectId();
            if (id == vr::k_unTrackedDeviceIndexInvalid)
                continue;

            const vr::DriverPose_t pose = hmd->GetPose();
            vr::VRServerDriverHost()->TrackedDevicePoseUpdated(
                id, pose, sizeof(vr::DriverPose_t));
        }
    }

    bool ShouldBlockStandbyMode() override { return false; }
    void EnterStandby() override {}
    void LeaveStandby() override {}

private:
    SOCKET sock = INVALID_SOCKET;
    IPhoneVRHMD* hmd = nullptr;
    WSADATA wsa{};
    bool wsaStarted = false;
};

static IPhoneVRProvider provider;

extern "C" __declspec(dllexport)
void* HmdDriverFactory(const char* name, int* returnCode) {
    if (returnCode)
        *returnCode = vr::VRInitError_None;

    if (name && std::strcmp(name, vr::IServerTrackedDeviceProvider_Version) == 0)
        return &provider;

    if (returnCode)
        *returnCode = vr::VRInitError_Init_InterfaceNotFound;

    return nullptr;
}
