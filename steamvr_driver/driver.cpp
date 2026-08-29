#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cmath>
#include <cstring>
#include <string>
#include "openvr_driver.h"

#pragma comment(lib, "Ws2_32.lib")

static constexpr unsigned short kPort = 1533;
static constexpr float kPi = 3.14159265358979323846f;

class IPhoneVRHMD final : public vr::ITrackedDeviceServerDriver {
public:
    vr::EVRInitError Activate(uint32_t unObjectId) override {
        objectId = unObjectId;
        auto props = vr::VRProperties();
        propertyContainer = props->TrackedDeviceToPropertyContainer(objectId);
        props->SetStringProperty(propertyContainer, vr::Prop_TrackingSystemName_String, "iPhoneVR");
        props->SetStringProperty(propertyContainer, vr::Prop_ModelNumber_String, "iPhone 11 VR");
        props->SetStringProperty(propertyContainer, vr::Prop_SerialNumber_String, "iPhoneVR-001");
        props->SetStringProperty(propertyContainer, vr::Prop_RenderModelName_String, "generic_hmd");
        props->SetBoolProperty(propertyContainer, vr::Prop_WillDriftInYaw_Bool, false);
        props->SetFloatProperty(propertyContainer, vr::Prop_UserIpdMeters_Float, 0.063f);
        props->SetUint64Property(propertyContainer, vr::Prop_CurrentUniverseId_Uint64, 1);
        return vr::VRInitError_None;
    }

    void Deactivate() override { objectId = vr::k_unTrackedDeviceIndexInvalid; }
    void EnterStandby() override {}
    void *GetComponent(const char *pchComponentNameAndVersion) override { return nullptr; }
    void DebugRequest(const char *pchRequest, char *pchResponseBuffer, uint32_t unResponseBufferSize) override {
        if (unResponseBufferSize) pchResponseBuffer[0] = '\0';
    }

    vr::DriverPose_t GetPose() override {
        std::lock_guard<std::mutex> lock(mutex);
        vr::DriverPose_t pose{};
        pose.poseTimeOffset = 0;
        pose.result = vr::TrackingResult_Running_OK;
        pose.poseIsValid = true;
        pose.deviceIsConnected = true;
        pose.willDriftInYaw = false;
        pose.shouldApplyHeadModel = false;
        pose.qWorldFromDriverRotation = {1,0,0,0};
        pose.qDriverFromHeadRotation = {1,0,0,0};
        pose.vecWorldFromDriverTranslation[0] = 0;
        pose.vecWorldFromDriverTranslation[1] = 0;
        pose.vecWorldFromDriverTranslation[2] = 0;
        pose.vecDriverFromHeadTranslation[0] = 0;
        pose.vecDriverFromHeadTranslation[1] = 0;
        pose.vecDriverFromHeadTranslation[2] = 0;
        pose.vecVelocity[0] = pose.vecVelocity[1] = pose.vecVelocity[2] = 0;
        pose.vecAngularVelocity[0] = pose.vecAngularVelocity[1] = pose.vecAngularVelocity[2] = 0;
        pose.qRotation = quaternion;
        return pose;
    }

    void SetAngles(float y, float p, float r) {
        std::lock_guard<std::mutex> lock(mutex);
        yaw = y * kPi / 180.0f;
        pitch = p * kPi / 180.0f;
        roll = r * kPi / 180.0f;
        const float cy = cosf(yaw * 0.5f), sy = sinf(yaw * 0.5f);
        const float cp = cosf(pitch * 0.5f), sp = sinf(pitch * 0.5f);
        const float cr = cosf(roll * 0.5f), sr = sinf(roll * 0.5f);
        quaternion.w = cr * cp * cy + sr * sp * sy;
        quaternion.x = sr * cp * cy - cr * sp * sy;
        quaternion.y = cr * sp * cy + sr * cp * sy;
        quaternion.z = cr * cp * sy - sr * sp * cy;
    }

    void SetObjectId(vr::TrackedDeviceIndex_t id) { objectId = id; }

private:
    vr::TrackedDeviceIndex_t objectId = vr::k_unTrackedDeviceIndexInvalid;
    vr::PropertyContainerHandle_t propertyContainer = vr::k_ulInvalidPropertyContainer;
    float yaw = 0, pitch = 0, roll = 0;
    vr::HmdQuaternion_t quaternion{1,0,0,0};
    std::mutex mutex;
};

class IPhoneVRProvider final : public vr::IServerTrackedDeviceProvider {
public:
    vr::EVRInitError Init(vr::IVRDriverContext *pDriverContext) override {
        VR_INIT_SERVER_DRIVER_CONTEXT(pDriverContext);
        WSADATA wsa{};
        if (WSAStartup(MAKEWORD(2,2), &wsa) != 0) return vr::VRInitError_Driver_Failed;
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock == INVALID_SOCKET) return vr::VRInitError_Driver_Failed;
        u_long nonblock = 1;
        ioctlsocket(sock, FIONBIO, &nonblock);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(kPort);
        if (bind(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
            closesocket(sock); sock = INVALID_SOCKET; WSACleanup(); return vr::VRInitError_Driver_Failed;
        }
        hmd = new IPhoneVRHMD();
        vr::VRServerDriverHost()->TrackedDeviceAdded("iPhoneVR-HMD", vr::TrackedDeviceClass_HMD, hmd);
        return vr::VRInitError_None;
    }

    void Cleanup() override {
        if (sock != INVALID_SOCKET) { closesocket(sock); sock = INVALID_SOCKET; }
        WSACleanup();
        delete hmd; hmd = nullptr;
        VR_CLEANUP_SERVER_DRIVER_CONTEXT();
    }

    const char * const *GetInterfaceVersions() override { return vr::k_InterfaceVersions; }
    void RunFrame() override {
        if (sock == INVALID_SOCKET || !hmd) return;
        char buf[256];
        sockaddr_in from{}; int fromLen = sizeof(from);
        int n;
        while ((n = recvfrom(sock, buf, sizeof(buf)-1, 0, reinterpret_cast<sockaddr*>(&from), &fromLen)) > 0) {
            buf[n] = '\0';
            float y,p,r;
            if (sscanf_s(buf, "%f,%f,%f", &y, &p, &r) == 3) {
                hmd->SetAngles(y,p,r);
                vr::DriverPose_t pose = hmd->GetPose();
                vr::VRServerDriverHost()->TrackedDevicePoseUpdated(0, pose, sizeof(pose));
            }
        }
    }
    bool ShouldBlockStandbyMode() override { return false; }
    void EnterStandby() override {}
    void LeaveStandby() override {}

private:
    SOCKET sock = INVALID_SOCKET;
    IPhoneVRHMD *hmd = nullptr;
};

static IPhoneVRProvider g_provider;

extern "C" __declspec(dllexport) void *HmdDriverFactory(const char *pInterfaceName, int *pReturnCode) {
    if (pReturnCode) *pReturnCode = vr::VRInitError_None;
    if (std::strcmp(pInterfaceName, vr::IServerTrackedDeviceProvider_Version) == 0) return &g_provider;
    if (pReturnCode) *pReturnCode = vr::VRInitError_Init_InterfaceNotFound;
    return nullptr;
}
