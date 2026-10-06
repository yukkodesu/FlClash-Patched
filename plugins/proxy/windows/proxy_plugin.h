#ifndef FLUTTER_PLUGIN_PROXY_PLUGIN_H_
#define FLUTTER_PLUGIN_PROXY_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace proxy
{

struct ProxySettings
{
  DWORD flags = 0;
  std::wstring server;
  std::wstring bypass;
};

enum ProxyFields : unsigned
{
  kFlags = 1,
  kServer = 2,
  kBypass = 4
};

class ProxySettingsBackend
{
 public:
  virtual ~ProxySettingsBackend() = default;
  virtual bool Connections(std::vector<std::wstring>& connections) = 0;
  virtual bool Read(const std::wstring& connection,
                    ProxySettings& settings) = 0;
  virtual bool Write(const std::wstring& connection,
                     const ProxySettings& settings, unsigned fields) = 0;
  virtual bool Notify() = 0;
};

std::unique_ptr<ProxySettingsBackend> CreateProxySettingsBackend();

class ProxyPlugin : public flutter::Plugin
{
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ProxyPlugin();

  explicit ProxyPlugin(std::unique_ptr<ProxySettingsBackend> backend);

  explicit ProxyPlugin(flutter::PluginRegistrarWindows* registrar);

  ~ProxyPlugin() override;

  ProxyPlugin(const ProxyPlugin&) = delete;
  ProxyPlugin& operator=(const ProxyPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static bool IsSessionEnding(UINT message, WPARAM wparam);

  std::optional<LRESULT> HandleWindowProc(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam);

 private:
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  int window_proc_id_ = -1;
  struct OwnedConnection
  {
    std::wstring name;
    ProxySettings before;
    ProxySettings installed;
    unsigned pending;
    bool server_restored = false;
  };
  std::unique_ptr<ProxySettingsBackend> backend_;
  std::vector<OwnedConnection> owned_;
  bool notification_pending_ = false;
  bool session_ending_ = false;
  bool Start(int port, const flutter::EncodableList& bypass);
  bool Stop();
};

}  // namespace proxy

#endif  // FLUTTER_PLUGIN_PROXY_PLUGIN_H_
