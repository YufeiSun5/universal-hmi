#include "desktop_lifecycle.h"

#include <bcrypt.h>
#include <sddl.h>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cwctype>
#include <stdexcept>
#include <vector>
#include "resource.h"

namespace {
constexpr UINT kTray = WM_APP + 71;
constexpr UINT kActivate = WM_APP + 72;
constexpr UINT kHide = 0x1f10;
constexpr UINT kSystemExit = 0x1f20;
constexpr UINT kOpen = 1;
constexpr UINT kExit = 2;

std::wstring Environment(const wchar_t* name) {
  DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
  if (!length) return {};
  std::wstring value(length, L'\0');
  GetEnvironmentVariableW(name, value.data(), length);
  value.resize(length - 1);
  return value;
}
std::wstring Wide(const std::string& value) {
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                static_cast<int>(value.size()), nullptr, 0);
  if (!size && !value.empty()) throw std::runtime_error("Invalid UTF-8 identity");
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}
std::string Argument(const flutter::EncodableMap& args, const char* key) {
  auto found = args.find(flutter::EncodableValue(key));
  if (found == args.end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  return value ? *value : std::string();
}
std::wstring CanonicalDirectory(std::wstring value) {
  DWORD size = GetFullPathNameW(value.c_str(), 0, nullptr, nullptr);
  if (!size) throw std::runtime_error("Cannot resolve project directory");
  std::wstring full(size, L'\0');
  DWORD length = GetFullPathNameW(value.c_str(), size, full.data(), nullptr);
  if (!length || length >= size) throw std::runtime_error("Invalid project directory");
  full.resize(length);
  HANDLE directory = CreateFileW(full.c_str(), 0,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (directory != INVALID_HANDLE_VALUE) {
    size = GetFinalPathNameByHandleW(directory, nullptr, 0, FILE_NAME_NORMALIZED);
    if (size) {
      std::wstring resolved(size + 1, L'\0');
      length = GetFinalPathNameByHandleW(directory, resolved.data(), size + 1,
                                       FILE_NAME_NORMALIZED);
      if (length && length <= size) {
        resolved.resize(length);
        full = resolved;
      }
    }
    CloseHandle(directory);
  }
  if (full.rfind(L"\\\\?\\UNC\\", 0) == 0) full = L"\\\\" + full.substr(8);
  else if (full.rfind(L"\\\\?\\", 0) == 0) full = full.substr(4);
  std::replace(full.begin(), full.end(), L'/', L'\\');
  while (full.size() > 3 && full.back() == L'\\') full.pop_back();
  std::transform(full.begin(), full.end(), full.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  return full;
}
std::wstring UserIdentity() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    throw std::runtime_error("Cannot identify Windows user");
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  bool ok = GetTokenInformation(token, TokenUser, buffer.data(), size, &size) != 0;
  CloseHandle(token);
  if (!ok) throw std::runtime_error("Cannot read Windows user");
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sid))
    throw std::runtime_error("Cannot encode Windows user");
  std::wstring result(sid);
  LocalFree(sid);
  return result;
}
std::wstring Digest(const std::wstring& input) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
    throw std::runtime_error("Cannot initialize project identity");
  BYTE hash[32];
  auto status = BCryptHash(algorithm, nullptr, 0,
      reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(input.data())),
      static_cast<ULONG>(input.size() * sizeof(wchar_t)), hash, sizeof(hash));
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (status < 0) throw std::runtime_error("Cannot hash project identity");
  std::wstring result;
  for (BYTE byte : hash) {
    result += L"0123456789abcdef"[byte >> 4];
    result += L"0123456789abcdef"[byte & 15];
  }
  return result;
}
struct WindowSearch { const wchar_t* property; HWND result = nullptr; };
BOOL CALLBACK FindInstance(HWND window, LPARAM param) {
  auto* search = reinterpret_cast<WindowSearch*>(param);
  if (GetPropW(window, search->property)) { search->result = window; return FALSE; }
  return TRUE;
}
bool Claim(HANDLE& mutex, const std::wstring& name) {
  mutex = CreateMutexW(nullptr, TRUE, name.c_str());
  if (!mutex) throw std::runtime_error("Cannot lock desktop instance");
  if (GetLastError() != ERROR_ALREADY_EXISTS) return true;
  // A crashed owner leaves an abandoned mutex until the final handle closes.
  DWORD wait = WaitForSingleObject(mutex, 0);
  return wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED;
}
}

DesktopLifecycle::DesktopLifecycle(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "universal_hmi/desktop", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "approveExit") {
      exit_approved_ = true;
      result->Success();
      return;
    }
    if (call.method_name() != "initialize") { result->NotImplemented(); return; }
    try {
      const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!args) throw std::runtime_error("Missing desktop identity");
      bool accepted = Initialize(*args);
      result->Success(flutter::EncodableValue(accepted));
      if (!accepted) PostQuitMessage(0);
    } catch (const std::exception& error) {
      MessageBoxW(window_, L"无法确定工程实例，请从工程快捷方式启动。", L"Universal HMI", MB_OK | MB_ICONERROR);
      result->Error("desktop_identity", error.what());
      PostQuitMessage(1);
    }
  });
}
DesktopLifecycle::~DesktopLifecycle() {
  // MethodChannel's destructor does not unregister its captured-this handler.
  channel_->SetMethodCallHandler(nullptr);
  if (tray_added_) { NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = window_; data.uID = 1; Shell_NotifyIconW(NIM_DELETE, &data); }
  if (!property_.empty()) RemovePropW(window_, property_.c_str());
  if (instance_mutex_) { ReleaseMutex(instance_mutex_); CloseHandle(instance_mutex_); }
  if (bare_mutex_) { ReleaseMutex(bare_mutex_); CloseHandle(bare_mutex_); }
}
bool DesktopLifecycle::Initialize(const flutter::EncodableMap& args) {
  if (initialized_) return true;
  role_ = Argument(args, "role") == "developer" ? L"开发端" : L"用户端";
  std::wstring project = Environment(L"HMI_PROJECT_DIR");
  if (project.empty()) project = Environment(L"HMI_DATA_DIR");
  std::wstring endpoint = Wide(Argument(args, "endpoint"));
  std::wstring identity;
  const auto remote_key = args.find(flutter::EncodableValue("remote"));
  const bool remote = remote_key != args.end() &&
      std::get_if<bool>(&remote_key->second) && std::get<bool>(remote_key->second);
  if (remote && !endpoint.empty()) identity = L"endpoint:" + endpoint;
  else if (!project.empty()) identity = L"directory:" + CanonicalDirectory(project);
  else if (!endpoint.empty()) identity = L"endpoint:" + endpoint;
  else {
    project = Environment(L"LOCALAPPDATA");
    if (project.empty()) throw std::runtime_error("LOCALAPPDATA is missing");
    identity = L"directory:" + CanonicalDirectory(project + L"\\universal-hmi");
  }
  std::wstring base = L"Local\\UniversalHmi." + Digest(UserIdentity() + L"|" + identity);
  std::wstring role = Argument(args, "role") == "developer" ? L"developer" : L"runtime";
  property_ = L"UniversalHmi.Instance." + Digest(base + L"|" + role);
  bool claimed = Claim(instance_mutex_, base + L"." + role);
  if (!claimed) {
    WindowSearch search{property_.c_str()};
    for (int attempt = 0; attempt < 100; ++attempt) {
      EnumWindows(FindInstance, reinterpret_cast<LPARAM>(&search));
      if (search.result) {
        DWORD pid = 0; GetWindowThreadProcessId(search.result, &pid);
        AllowSetForegroundWindow(pid);
        PostMessageW(search.result, kActivate, 0, 0);
        return false;
      }
      DWORD wait = WaitForSingleObject(instance_mutex_, 50);
      if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) { claimed = true; break; }
      if (wait != WAIT_TIMEOUT) break;
    }
    // Do not create another backend when an owner is starting or unresponsive.
    if (!claimed) {
      MessageBoxW(window_, L"该端已在启动或运行，请稍后从工程快捷方式再次打开。", L"Universal HMI", MB_OK | MB_ICONINFORMATION);
      return false;
    }
  }
  if (endpoint.empty() && !Claim(bare_mutex_, base + L".bare")) {
    MessageBoxW(window_, L"同一工程已有直接启动的窗口。请使用工程的开发端和运行端快捷方式双端并存。", L"Universal HMI", MB_OK | MB_ICONINFORMATION);
    return false;
  }
  if (!SetPropW(window_, property_.c_str(), reinterpret_cast<HANDLE>(1)))
    throw std::runtime_error("Cannot publish desktop instance");
  initialized_ = true;
  SetWindowTextW(window_, (L"Universal HMI · " + role_).c_str());
  HMENU menu = GetSystemMenu(window_, FALSE);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kHide, L"收起到托盘");
  AppendMenuW(menu, MF_STRING, kSystemExit, L"退出此端");
  AddTray();
  return true;
}
bool DesktopLifecycle::AddTray() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data); data.hWnd = window_; data.uID = 1;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTray;
  data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  std::wstring tip = L"Universal HMI · " + role_;
  wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  return tray_added_;
}
void DesktopLifecycle::Open() {
  ShowWindow(window_, hidden_maximized_ ? SW_SHOWMAXIMIZED : (IsIconic(window_) ? SW_RESTORE : SW_SHOW));
  hidden_maximized_ = false;
  SetForegroundWindow(window_);
}
void DesktopLifecycle::Hide() {
  if (!tray_added_ && !AddTray()) {
    Open();
    MessageBoxW(window_, L"托盘暂不可用，窗口保持打开。可通过系统菜单“退出此端”或稍后重试。", L"Universal HMI", MB_OK | MB_ICONINFORMATION);
    return;
  }
  hidden_maximized_ = IsZoomed(window_) != FALSE;
  ShowWindow(window_, SW_HIDE);
}
void DesktopLifecycle::Exit() {
  Open();
  channel_->InvokeMethod("requestExit", nullptr);
}
void DesktopLifecycle::Menu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kOpen, (L"打开" + role_).c_str());
  AppendMenuW(menu, MF_STRING, kExit, (L"退出" + role_).c_str());
  POINT point; GetCursorPos(&point);
  SetForegroundWindow(window_);
  int selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                               point.x, point.y, 0, window_, nullptr);
  DestroyMenu(menu);
  PostMessageW(window_, WM_NULL, 0, 0);
  if (selected == kOpen) Open();
  else if (selected == kExit) Exit();
}
std::optional<LRESULT> DesktopLifecycle::Handle(UINT message, WPARAM wparam, LPARAM lparam) {
  if (!initialized_) return std::nullopt;
  if (message == kActivate) { Open(); return 0; }
  if (message == taskbar_created_) {
    tray_added_ = false;
    if (!AddTray()) Open();
    return 0;
  }
  if (message == WM_CLOSE && !exit_approved_) { Hide(); return 0; }
  if (message == WM_SYSCOMMAND && (wparam & 0xfff0) == kHide) { Hide(); return 0; }
  if (message == WM_SYSCOMMAND && (wparam & 0xfff0) == kSystemExit) { Exit(); return 0; }
  if (message == kTray) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) Open();
    else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) Menu();
    return 0;
  }
  return std::nullopt;
}
