// bluetooth.cpp - BT probe, reconnect, enumeration
#include "bluetooth.h"

// ---------------------------------------------------------------------------
// Dual-socket BT probe
// ---------------------------------------------------------------------------
static SOCKET s_persistSocket = INVALID_SOCKET;

static bool IsSocketAlive() {
    if (s_persistSocket == INVALID_SOCKET) return false;
    char buf;
    int r = recv(s_persistSocket, &buf, 1, MSG_PEEK);
    if (r == 0 || (r == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK
                                     && WSAGetLastError() != WSAETIMEDOUT)) {
        closesocket(s_persistSocket); s_persistSocket = INVALID_SOCKET; return false;
    }
    return true;
}

static DWORD MeasureLatency(BTH_ADDR target) {
    SOCKET s = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    if (s == INVALID_SOCKET) return 9999;
    DWORD to = RFCOMM_CONNECT_TIMEOUT_MS;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&to, sizeof(to));
    SOCKADDR_BTH sa = {};
    sa.addressFamily = AF_BTH; sa.btAddr = target;
    sa.serviceClassId = OBEXObjectPushServiceClass_UUID; sa.port = 0;
    LARGE_INTEGER freq, t1, t2;
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&t1);
    connect(s, (SOCKADDR*)&sa, sizeof(sa));
    QueryPerformanceCounter(&t2);
    closesocket(s);
    return (DWORD)((t2.QuadPart - t1.QuadPart) * 1000 / freq.QuadPart);
}

static bool EstablishPersist(BTH_ADDR target, DWORD& outLatency, int& outErr) {
    SOCKET s = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    if (s == INVALID_SOCKET) { outErr = WSAGetLastError(); return false; }
    DWORD to = RFCOMM_CONNECT_TIMEOUT_MS;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&to, sizeof(to));
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&to, sizeof(to));
    SOCKADDR_BTH sa = {};
    sa.addressFamily = AF_BTH; sa.btAddr = target;
    sa.serviceClassId = SerialPortServiceClass_UUID; sa.port = 0;
    LARGE_INTEGER freq, t1, t2;
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&t1);
    int ret = connect(s, (SOCKADDR*)&sa, sizeof(sa));
    QueryPerformanceCounter(&t2);
    outLatency = (DWORD)((t2.QuadPart - t1.QuadPart) * 1000 / freq.QuadPart);
    if (ret == 0) {
        DWORD rv = 100; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&rv, sizeof(rv));
        s_persistSocket = s; return true;
    }
    outErr = WSAGetLastError(); closesocket(s);
    return (outErr == WSAECONNREFUSED || outErr == WSAECONNRESET);
}

void DoProbe(BTH_ADDR target, bool& outReachable, DWORD& outLatency, int& outErr) {
    outReachable = false; outLatency = 0; outErr = 0;
    if (s_persistSocket != INVALID_SOCKET) {
        if (IsSocketAlive()) {
            outReachable = true;
            outLatency = MeasureLatency(target);
            g_consecutiveFails = 0;
            return;
        }
    }
    bool connected = EstablishPersist(target, outLatency, outErr);
    if (connected || outErr == WSAECONNREFUSED || outErr == WSAECONNRESET) {
        outReachable = true;
        if (g_consecutiveFails >= 3) g_reconnectTick = GetTickCount64();
        g_consecutiveFails = 0;
    } else {
        g_consecutiveFails++;
    }
}

void CloseProbeSocket() {
    if (s_persistSocket != INVALID_SOCKET) {
        closesocket(s_persistSocket); s_persistSocket = INVALID_SOCKET;
    }
}

// ---------------------------------------------------------------------------
// Reconnect
// ---------------------------------------------------------------------------
bool IsOsConnected(BTH_ADDR target) {
    BLUETOOTH_FIND_RADIO_PARAMS rp = { sizeof(rp) };
    HANDLE hRadio = nullptr;
    HBLUETOOTH_RADIO_FIND hFind = BluetoothFindFirstRadio(&rp, &hRadio);
    if (!hFind) return false;
    BLUETOOTH_DEVICE_INFO di = {}; di.dwSize = sizeof(di); di.Address.ullLong = target;
    DWORD ret = BluetoothGetDeviceInfo(hRadio, &di);
    CloseHandle(hRadio); BluetoothFindRadioClose(hFind);
    return (ret == ERROR_SUCCESS && di.fConnected);
}

void ReconnectDevice(BTH_ADDR target) {
    BLUETOOTH_FIND_RADIO_PARAMS rp = { sizeof(rp) };
    HANDLE hRadio = nullptr;
    HBLUETOOTH_RADIO_FIND hFind = BluetoothFindFirstRadio(&rp, &hRadio);
    if (!hFind) return;

    BLUETOOTH_DEVICE_SEARCH_PARAMS sp = {};
    sp.dwSize = sizeof(sp);
    sp.fReturnAuthenticated = TRUE; sp.fReturnRemembered = TRUE;
    sp.fReturnConnected = TRUE; sp.fIssueInquiry = TRUE;
    sp.hRadio = hRadio; sp.cTimeoutMultiplier = 2;
    BLUETOOTH_DEVICE_INFO di = {}; di.dwSize = sizeof(di);
    HBLUETOOTH_DEVICE_FIND hDev = BluetoothFindFirstDevice(&sp, &di);
    if (hDev) { do { } while (BluetoothFindNextDevice(hDev, &di)); BluetoothFindDeviceClose(hDev); }

    di = {}; di.dwSize = sizeof(di); di.Address.ullLong = target;
    BluetoothGetDeviceInfo(hRadio, &di);
    BluetoothAuthenticateDeviceEx(nullptr, hRadio, &di, nullptr, MITMProtectionNotRequiredBonding);
    Sleep(2000);
    GUID hfp = HandsfreeServiceClass_UUID;
    BluetoothSetServiceState(hRadio, &di, &hfp, BLUETOOTH_SERVICE_ENABLE);
    GUID a2dp = AudioSinkServiceClass_UUID;
    BluetoothSetServiceState(hRadio, &di, &a2dp, BLUETOOTH_SERVICE_ENABLE);
    CloseHandle(hRadio); BluetoothFindRadioClose(hFind);
}

// ---------------------------------------------------------------------------
// Enumerate paired devices
// ---------------------------------------------------------------------------
void EnumPaired() {
    g_paired.clear();
    BLUETOOTH_FIND_RADIO_PARAMS rp = { sizeof(rp) };
    HANDLE hR = nullptr;
    HBLUETOOTH_RADIO_FIND hF = BluetoothFindFirstRadio(&rp, &hR);
    if (!hF) return;
    do {
        BLUETOOTH_DEVICE_SEARCH_PARAMS sp = {}; sp.dwSize = sizeof(sp);
        sp.fReturnAuthenticated = TRUE; sp.fReturnRemembered = TRUE;
        sp.fReturnConnected = TRUE; sp.fIssueInquiry = FALSE; sp.hRadio = hR;
        BLUETOOTH_DEVICE_INFO di = {}; di.dwSize = sizeof(di);
        HBLUETOOTH_DEVICE_FIND hD = BluetoothFindFirstDevice(&sp, &di);
        if (hD) {
            do { g_paired.push_back({ di.Address.ullLong, di.szName, di.fConnected != 0 }); }
            while (BluetoothFindNextDevice(hD, &di));
            BluetoothFindDeviceClose(hD);
        }
        CloseHandle(hR); hR = nullptr;
    } while (BluetoothFindNextRadio(hF, &hR));
    BluetoothFindRadioClose(hF);
}
