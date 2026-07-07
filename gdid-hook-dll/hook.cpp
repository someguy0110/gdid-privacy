#include "hook.h"
#include <MinHook.h>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <sstream>
#include <iomanip>
#include <random>
#include <winternl.h>

// ---------- Target paths ----------
static const struct {
    HKEY root;
    const wchar_t* subKey;
    const wchar_t* value;
} GDID_TARGETS[] = {
    { HKEY_CURRENT_USER,  L"SOFTWARE\\Microsoft\\IdentityCRL\\ExtendedProperties",                          L"LID" },
    { HKEY_CURRENT_USER,  L"SOFTWARE\\Microsoft\\IdentityCRL\\Immersive\\production\\Token",              L"DeviceId" },
    { HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\IdentityCRL\\NegativeCache",                             L"DeviceId" },
    { HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\IdentityStore\\Cache\\DeviceIdentity",                  L"DeviceId" },
};
static const int GDID_TARGET_COUNT = sizeof(GDID_TARGETS) / sizeof(GDID_TARGETS[0]);

// ---------- Hook state ----------
static decltype(&RegQueryValueExW) RealRegQueryValueExW = nullptr;
static bool hooksInstalled = false;
static bool logEnabled = false;

// ---------- Generate fake GDID ----------
std::wstring GenerateFakeGDID() {
    static std::random_device rd;
    static std::mt19937_64 gen(rd());
    static std::uniform_int_distribution<uint64_t> dist(0, UINT64_MAX);

    uint64_t val = dist(gen);
    // 0018 prefix (Device PUID namespace) + 46 random bits
    val = (val & 0x00FFFFFFFFFFFFFF) | 0x0018000000000000;

    std::wstringstream ss;
    ss << std::hex << std::uppercase << std::setw(16) << std::setfill(L'0') << val;
    return ss.str();
}

// ---------- Resolve key handle to full path via NtQueryKey ----------
static std::wstring GetKeyPath(HKEY hKey) {
    std::wstring path;
    // Try NtQueryKey first (undocumented but stable)
    typedef NTSTATUS(NTAPI* pNtQueryKey)(HANDLE, KEY_INFORMATION_CLASS, PVOID, ULONG, PULONG);
    static auto NtQueryKey = (pNtQueryKey)GetProcAddress(
        GetModuleHandleW(L"ntdll.dll"), "NtQueryKey");

    if (NtQueryKey) {
        ULONG size = 0;
        NTSTATUS status = NtQueryKey(hKey, KeyNameInformation, nullptr, 0, &size);
        if (status == STATUS_BUFFER_TOO_SMALL || status == STATUS_INFO_LENGTH_MISMATCH) {
            std::vector<BYTE> buf(size);
            status = NtQueryKey(hKey, KeyNameInformation, buf.data(), size, &size);
            if (status >= 0) {
                PKEY_NAME_INFORMATION nameInfo = (PKEY_NAME_INFORMATION)buf.data();
                path = std::wstring(nameInfo->Name, nameInfo->NameLength / sizeof(wchar_t));
                // Remove the \REGISTRY\MACHINE or \REGISTRY\USER prefix
                if (path.find(L"\\REGISTRY\\MACHINE\\") == 0) {
                    path = L"HKLM\\" + path.substr(18);
                } else if (path.find(L"\\REGISTRY\\USER\\") == 0) {
                    path = L"HKU\\" + path.substr(15);
                } else if (path.find(L"\\REGISTRY\\") == 0) {
                    // Unknown registry root
                }
                return path;
            }
        }
    }

    // Fallback: try querying info iteratively (slow)
    wchar_t buf[512];
    DWORD bufLen = 512;
    HKEY hParent = hKey;
    // Walk up once
    if (RegQueryInfoKeyW(hKey, buf, &bufLen, nullptr, nullptr, nullptr,
                         nullptr, nullptr, nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS) {
        path = buf;
    }

    return path;
}

// ---------- Check if this handle+value matches a GDID target ----------
static bool IsGDIDQuery(HKEY hKey, LPCWSTR lpValueName) {
    if (!lpValueName) return false;

    // Fast check: try opening each known GDID path and see if
    // the value at that path matches what we're reading.
    // More reliable than path string matching since handles can be nested.
    for (int i = 0; i < GDID_TARGET_COUNT; i++) {
        if (_wcsicmp(lpValueName, GDID_TARGETS[i].value) != 0)
            continue;

        // Check if this key handle could be our target by trying
        // to open the full known path
        HKEY hTest;
        if (RegOpenKeyExW(GDID_TARGETS[i].root, GDID_TARGETS[i].subKey,
                          0, KEY_READ, &hTest) == ERROR_SUCCESS) {
            // Read the value from our known path
            wchar_t testBuf[256] = {0};
            DWORD testType = 0;
            DWORD testSize = sizeof(testBuf);
            LSTATUS testResult = RealRegQueryValueExW(
                hTest, GDID_TARGETS[i].value, nullptr,
                &testType, (LPBYTE)testBuf, &testSize);
            RegCloseKey(hTest);

            // If the real value exists at this path, the handle is
            // pointing to something in this subtree.
            if (testResult == ERROR_SUCCESS) {
                // Now check if the passed handle hKey also has this value
                // by trying to read from hKey directly (using real function
                // to avoid recursion since this IS the hook)
                if (logEnabled) {
                    OutputDebugStringW(L"gdid-hook: intercepted GDID query");
                }
                return true;
            }
        }
    }

    return false;
}

// ---------- Hooked RegQueryValueExW ----------
LSTATUS WINAPI HookRegQueryValueExW(
    HKEY    hKey,
    LPCWSTR lpValueName,
    LPDWORD lpReserved,
    LPDWORD lpType,
    LPBYTE  lpData,
    LPDWORD lpcbData)
{
    if (!IsGDIDQuery(hKey, lpValueName)) {
        return RealRegQueryValueExW(hKey, lpValueName, lpReserved,
                                     lpType, lpData, lpcbData);
    }

    // Generate fake GDID
    std::wstring fakeGdid = GenerateFakeGDID();
    const wchar_t* fakeStr = fakeGdid.c_str();
    DWORD needed = static_cast<DWORD>((fakeGdid.length() + 1) * sizeof(wchar_t));

    if (lpData && lpcbData) {
        if (*lpcbData >= needed) {
            memcpy(lpData, fakeStr, needed);
        }
        *lpcbData = needed;
    }

    // Return real type as string
    if (lpType) {
        *lpType = REG_SZ;
    }

    if (logEnabled) {
        wchar_t msg[512];
        swprintf_s(msg, L"gdid-hook: spoofed %s -> %s",
                   lpValueName ? lpValueName : L"(null)", fakeStr);
        OutputDebugStringW(msg);
    }

    return ERROR_SUCCESS;
}

// ---------- Public API ----------
BOOL InstallHooks() {
    if (hooksInstalled) return TRUE;

    if (MH_Initialize() != MH_OK) {
        return FALSE;
    }

    if (MH_CreateHookApi(
            L"advapi32.dll",
            "RegQueryValueExW",
            HookRegQueryValueExW,
            reinterpret_cast<LPVOID*>(&RealRegQueryValueExW)) != MH_OK) {
        MH_Uninitialize();
        return FALSE;
    }

    if (MH_EnableHook(MH_ALL_HOOKS) != MH_OK) {
        MH_RemoveHook(reinterpret_cast<LPVOID*>(RealRegQueryValueExW));
        MH_Uninitialize();
        return FALSE;
    }

    hooksInstalled = true;
    return TRUE;
}

void RemoveHooks() {
    if (!hooksInstalled) return;
    MH_DisableHook(MH_ALL_HOOKS);
    MH_RemoveHook(reinterpret_cast<LPVOID*>(RealRegQueryValueExW));
    MH_Uninitialize();
    hooksInstalled = false;
}

void EnableLogging(BOOL enable) {
    logEnabled = enable != FALSE;
}