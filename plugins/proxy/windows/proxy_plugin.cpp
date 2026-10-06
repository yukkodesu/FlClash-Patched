// WinInet and RAS require Windows types to be declared first.
#include <windows.h>

#include "proxy_plugin.h"

#include <Ras.h>
#include <RasError.h>
#include <WinInet.h>

#include <algorithm>
#include <string>
#include <vector>

#pragma comment(lib, "wininet")
#pragma comment(lib, "Rasapi32")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace
{

constexpr int kMinProxyPort = 1;
constexpr int kMaxProxyPort = 65535;

std::wstring Utf8ToWide(const std::string& value)
{
  if (value.empty())
  {
    return {};
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0)
  {
    return std::wstring(value.begin(), value.end());
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::wstring BuildBypassList(const flutter::EncodableList& bypassDomain)
{
  std::wstring bypassList;
  for (const auto& domain : bypassDomain)
  {
    const auto& value = std::get<std::string>(domain);
    if (!bypassList.empty())
    {
      bypassList += L";";
    }
    bypassList += Utf8ToWide(value);
  }
  return bypassList;
}

bool IsStringList(const flutter::EncodableList& values)
{
  return std::all_of(values.begin(), values.end(), [](const auto& value)
                     { return std::holds_alternative<std::string>(value); });
}

class WinInetBackend : public proxy::ProxySettingsBackend
{
 public:
  bool Connections(std::vector<std::wstring>& connections) override
  {
    connections = {L""};
    DWORD size = 0;
    DWORD count = 0;
    auto status = RasEnumEntriesW(nullptr, nullptr, nullptr, &size, &count);
    if (status == ERROR_SUCCESS) return true;
    if (status != ERROR_BUFFER_TOO_SMALL || count == 0) return false;
    std::vector<RASENTRYNAMEW> entries(count);
    for (auto& entry : entries) entry.dwSize = sizeof(RASENTRYNAMEW);
    status = RasEnumEntriesW(nullptr, nullptr, entries.data(), &size, &count);
    if (status != ERROR_SUCCESS) return false;
    for (DWORD index = 0; index < count; ++index)
      connections.emplace_back(entries[index].szEntryName);
    return true;
  }

  bool Read(const std::wstring& connection,
            proxy::ProxySettings& settings) override
  {
    INTERNET_PER_CONN_OPTIONW options[3] = {};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    INTERNET_PER_CONN_OPTION_LISTW list = {};
    list.dwSize = sizeof(list);
    list.pszConnection =
        connection.empty() ? nullptr : const_cast<wchar_t*>(connection.c_str());
    list.dwOptionCount = 3;
    list.pOptions = options;
    DWORD size = sizeof(list);
    const bool success =
        InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                             &list, &size) != FALSE;
    if (success)
    {
      settings.flags = options[0].Value.dwValue;
      settings.server = options[1].Value.pszValue == nullptr
                            ? L""
                            : options[1].Value.pszValue;
      settings.bypass = options[2].Value.pszValue == nullptr
                            ? L""
                            : options[2].Value.pszValue;
    }
    if (options[1].Value.pszValue != nullptr)
      GlobalFree(options[1].Value.pszValue);
    if (options[2].Value.pszValue != nullptr)
      GlobalFree(options[2].Value.pszValue);
    return success;
  }

  bool Write(const std::wstring& connection,
             const proxy::ProxySettings& settings, unsigned fields) override
  {
    std::vector<INTERNET_PER_CONN_OPTIONW> options;
    INTERNET_PER_CONN_OPTIONW option = {};
    if (fields & proxy::kFlags)
    {
      option.dwOption = INTERNET_PER_CONN_FLAGS;
      option.Value.dwValue = settings.flags;
      options.push_back(option);
    }
    if (fields & proxy::kServer)
    {
      option.dwOption = INTERNET_PER_CONN_PROXY_SERVER;
      option.Value.pszValue = const_cast<wchar_t*>(settings.server.c_str());
      options.push_back(option);
    }
    if (fields & proxy::kBypass)
    {
      option.dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
      option.Value.pszValue = const_cast<wchar_t*>(settings.bypass.c_str());
      options.push_back(option);
    }
    INTERNET_PER_CONN_OPTION_LISTW list = {};
    list.dwSize = sizeof(list);
    list.pszConnection =
        connection.empty() ? nullptr : const_cast<wchar_t*>(connection.c_str());
    list.dwOptionCount = static_cast<DWORD>(options.size());
    list.pOptions = options.data();
    return InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                              &list, sizeof(list)) != FALSE;
  }

  bool Notify() override
  {
    const bool changed =
        InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr,
                           0) != FALSE;
    const bool refreshed = InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH,
                                              nullptr, 0) != FALSE;
    return changed && refreshed;
  }
};

}  // namespace

namespace proxy
{

// static
void ProxyPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar)
{
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "proxy",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ProxyPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result)
      { plugin_pointer->HandleMethodCall(call, std::move(result)); });

  registrar->AddPlugin(std::move(plugin));
}

std::unique_ptr<ProxySettingsBackend> CreateProxySettingsBackend()
{
  return std::make_unique<WinInetBackend>();
}

ProxyPlugin::ProxyPlugin() : backend_(CreateProxySettingsBackend()) {}

ProxyPlugin::ProxyPlugin(std::unique_ptr<ProxySettingsBackend> backend)
    : backend_(std::move(backend))
{
}

ProxyPlugin::ProxyPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), backend_(CreateProxySettingsBackend())
{
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND window, UINT message, WPARAM wparam, LPARAM lparam)
      { return HandleWindowProc(window, message, wparam, lparam); });
}

ProxyPlugin::~ProxyPlugin()
{
  if (registrar_ != nullptr)
  {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }
}

bool ProxyPlugin::IsSessionEnding(UINT message, WPARAM wparam)
{
  return message == WM_ENDSESSION && wparam != FALSE;
}

// Shutting Windows down kills the process without running the Dart exit path,
// so the setting survives into a boot with nothing listening behind it.
std::optional<LRESULT> ProxyPlugin::HandleWindowProc(HWND window, UINT message,
                                                     WPARAM wparam,
                                                     LPARAM lparam)
{
  if (IsSessionEnding(message, wparam))
  {
    session_ending_ = true;
    Stop();
  }
  return std::nullopt;
}

bool ProxyPlugin::Start(int port, const flutter::EncodableList& bypass)
{
  if (session_ending_ || !Stop()) return false;
  std::vector<std::wstring> connections;
  if (!backend_->Connections(connections)) return false;
  const ProxySettings installed{PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY,
                                L"127.0.0.1:" + std::to_wstring(port),
                                BuildBypassList(bypass)};
  std::vector<OwnedConnection> snapshots;
  for (const auto& connection : connections)
  {
    ProxySettings before;
    if (!backend_->Read(connection, before)) return false;
    unsigned fields = 0;
    if (before.flags != installed.flags) fields |= kFlags;
    if (before.server != installed.server) fields |= kServer;
    if (before.bypass != installed.bypass) fields |= kBypass;
    snapshots.push_back({connection, before, installed, fields});
  }
  for (auto& snapshot : snapshots)
  {
    if (snapshot.pending == 0) continue;
    owned_.push_back(std::move(snapshot));
    auto& owned = owned_.back();
    notification_pending_ = true;
    const bool written = backend_->Write(owned.name, installed, owned.pending);
    ProxySettings current;
    if (!written || !backend_->Read(owned.name, current) ||
        current.flags != installed.flags ||
        current.server != installed.server ||
        current.bypass != installed.bypass)
      return false;
  }
  if (notification_pending_)
  {
    if (!backend_->Notify()) return false;
    notification_pending_ = false;
  }
  return true;
}

bool ProxyPlugin::Stop()
{
  bool success = true;
  for (auto& owned : owned_)
  {
    if (owned.pending == 0) continue;
    ProxySettings current;
    if (!backend_->Read(owned.name, current))
    {
      success = false;
      continue;
    }
    ProxySettings restore = current;
    unsigned fields = 0;
    if (owned.pending & kFlags)
    {
      const bool server_owned =
          current.server == owned.installed.server ||
          (owned.server_restored && current.server == owned.before.server);
      if (current.flags == owned.installed.flags && server_owned)
      {
        restore.flags = owned.before.flags;
        fields |= kFlags;
      }
      else
      {
        owned.pending &= ~kFlags;
      }
    }
    if (owned.pending & kServer)
    {
      if (current.server == owned.installed.server)
      {
        restore.server = owned.before.server;
        fields |= kServer;
      }
      else
      {
        owned.pending &= ~kServer;
      }
    }
    if (owned.pending & kBypass)
    {
      if (current.bypass == owned.installed.bypass)
      {
        restore.bypass = owned.before.bypass;
        fields |= kBypass;
      }
      else
      {
        owned.pending &= ~kBypass;
      }
    }
    if (fields == 0) continue;
    notification_pending_ = true;
    const bool written = backend_->Write(owned.name, restore, fields);
    ProxySettings after;
    if (!backend_->Read(owned.name, after))
    {
      success = false;
      continue;
    }
    if ((fields & kFlags) && after.flags == owned.before.flags)
      owned.pending &= ~kFlags;
    if ((fields & kServer) && after.server == owned.before.server)
    {
      owned.pending &= ~kServer;
      owned.server_restored = true;
    }
    if ((fields & kBypass) && after.bypass == owned.before.bypass)
      owned.pending &= ~kBypass;
    if (!written || owned.pending != 0) success = false;
  }
  if (notification_pending_)
  {
    if (backend_->Notify())
      notification_pending_ = false;
    else
      success = false;
  }
  if (success) owned_.clear();
  return success;
}

void ProxyPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
{
  if (method_call.method_name() == "StopProxy")
  {
    bool only_if_needed = false;
    const auto* value = method_call.arguments();
    if (value != nullptr && !std::holds_alternative<std::monostate>(*value))
    {
      const auto* arguments = std::get_if<flutter::EncodableMap>(value);
      if (arguments == nullptr)
      {
        result->Error("bad_args", "StopProxy requires an argument map");
        return;
      }
      const auto flag =
          arguments->find(flutter::EncodableValue("onlyIfNeeded"));
      if (flag != arguments->end())
      {
        const auto* enabled = std::get_if<bool>(&flag->second);
        if (enabled == nullptr)
        {
          result->Error("bad_args", "StopProxy onlyIfNeeded must be a bool");
          return;
        }
        only_if_needed = *enabled;
      }
    }
    if (only_if_needed && owned_.empty() && !notification_pending_)
    {
      result->Success(true);
      return;
    }
    result->Success(Stop());
  }
  else if (method_call.method_name() == "StartProxy")
  {
    auto* arguments =
        std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments == nullptr)
    {
      result->Error("bad_args", "StartProxy requires argument map");
      return;
    }
    auto portIt = arguments->find(flutter::EncodableValue("port"));
    auto bypassDomainIt =
        arguments->find(flutter::EncodableValue("bypassDomain"));
    if (portIt == arguments->end() || bypassDomainIt == arguments->end())
    {
      result->Error("bad_args", "StartProxy requires port and bypassDomain");
      return;
    }
    auto* port = std::get_if<int>(&portIt->second);
    auto* bypassDomain =
        std::get_if<flutter::EncodableList>(&bypassDomainIt->second);
    if (port == nullptr || bypassDomain == nullptr)
    {
      result->Error("bad_args", "StartProxy argument types are invalid");
      return;
    }
    if (*port < kMinProxyPort || *port > kMaxProxyPort)
    {
      result->Error("bad_args", "StartProxy port must be between 1 and 65535");
      return;
    }
    if (!IsStringList(*bypassDomain))
    {
      result->Error("bad_args",
                    "StartProxy bypassDomain must contain only strings");
      return;
    }
    result->Success(Start(*port, *bypassDomain));
  }
  else
  {
    result->NotImplemented();
  }
}
}  // namespace proxy
