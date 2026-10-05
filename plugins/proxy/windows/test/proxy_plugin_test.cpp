#include <windows.h>

#include "proxy_plugin.h"

#include <WinInet.h>
#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>

#include <map>
#include <memory>
#include <string>
#include <variant>

namespace proxy
{
namespace test
{

namespace
{

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

class FakeSettings : public ProxySettingsBackend
{
 public:
  std::vector<std::wstring> connections{L"", L"VPN"};
  std::map<std::wstring, ProxySettings> settings{
      {L"", {PROXY_TYPE_AUTO_PROXY_URL, L"original:8080", L"original"}},
      {L"VPN", {PROXY_TYPE_DIRECT, L"vpn:8080", L"vpn"}}};
  unsigned writes = 0;
  std::wstring fail_connection = L"never";
  bool fail_after_write = false;
  bool fail_read = false;
  bool notify_ok = true;
  bool Connections(std::vector<std::wstring>& result) override
  {
    result = connections;
    return true;
  }
  bool Read(const std::wstring& connection, ProxySettings& result) override
  {
    if (fail_read) return false;
    result = settings.at(connection);
    return true;
  }
  bool Write(const std::wstring& connection, const ProxySettings& value,
             unsigned fields) override
  {
    ++writes;
    if (connection == fail_connection && !fail_after_write) return false;
    auto& current = settings.at(connection);
    if (fields & kFlags) current.flags = value.flags;
    if (fields & kServer) current.server = value.server;
    if (fields & kBypass) current.bypass = value.bypass;
    return connection != fail_connection;
  }
  bool Notify() override { return notify_ok; }
};

bool Call(ProxyPlugin& plugin, const std::string& method,
          EncodableMap arguments = {})
{
  bool success = false;
  plugin.HandleMethodCall(
      MethodCall(method, std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          [&success](const EncodableValue* value)
          { success = value && std::get<bool>(*value); }, nullptr, nullptr));
  return success;
}

EncodableMap StartArguments()
{
  return {{EncodableValue("port"), EncodableValue(7890)},
          {EncodableValue("bypassDomain"),
           EncodableValue(EncodableList{EncodableValue("local")})}};
}

TEST(ProxyOwnership, InactiveStopDoesNotWriteAnyForeignSettings)
{
  auto backend = std::make_unique<FakeSettings>();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  EXPECT_TRUE(Call(plugin, "StopProxy"));
  plugin.HandleWindowProc(nullptr, WM_ENDSESSION, TRUE, 0);
  EXPECT_EQ(os->writes, 0u);
  EXPECT_EQ(os->settings[L""].flags, PROXY_TYPE_AUTO_PROXY_URL);
}

TEST(ProxyOwnership,
     RestoresOriginalFlagsServerBypassAndOnlyOriginalConnections)
{
  auto backend = std::make_unique<FakeSettings>();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  EXPECT_TRUE(Call(plugin, "StartProxy", StartArguments()));
  os->connections = {L"new"};
  os->settings[L"new"] = {PROXY_TYPE_PROXY, L"later:80", L"later"};
  EXPECT_TRUE(Call(plugin, "StopProxy"));
  EXPECT_EQ(os->settings[L""].flags, PROXY_TYPE_AUTO_PROXY_URL);
  EXPECT_EQ(os->settings[L""].server, L"original:8080");
  EXPECT_EQ(os->settings[L""].bypass, L"original");
  EXPECT_EQ(os->settings[L"VPN"].server, L"vpn:8080");
  EXPECT_EQ(os->settings[L"new"].server, L"later:80");
  const auto writes = os->writes;
  EXPECT_TRUE(Call(plugin, "StopProxy"));
  EXPECT_EQ(os->writes, writes);
}

TEST(ProxyOwnership, LaterServerWriterKeepsItsProxyActivationDuringSessionEnd)
{
  auto backend = std::make_unique<FakeSettings>();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  EXPECT_TRUE(Call(plugin, "StartProxy", StartArguments()));
  os->settings[L""].server = L"later:8081";
  os->settings[L""].bypass = L"later";
  plugin.HandleWindowProc(nullptr, WM_ENDSESSION, TRUE, 0);
  EXPECT_EQ(os->settings[L""].server, L"later:8081");
  EXPECT_EQ(os->settings[L""].bypass, L"later");
  EXPECT_EQ(os->settings[L""].flags, PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY);
  EXPECT_FALSE(Call(plugin, "StartProxy", StartArguments()));
}

TEST(ProxyOwnership, LaterBypassAndPacFlagsSurviveOwnedServerRestoration)
{
  auto backend = std::make_unique<FakeSettings>();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  EXPECT_TRUE(Call(plugin, "StartProxy", StartArguments()));
  os->settings[L""].flags = PROXY_TYPE_AUTO_DETECT;
  os->settings[L""].bypass = L"later";
  EXPECT_TRUE(Call(plugin, "StopProxy"));
  EXPECT_EQ(os->settings[L""].server, L"original:8080");
  EXPECT_EQ(os->settings[L""].flags, PROXY_TYPE_AUTO_DETECT);
  EXPECT_EQ(os->settings[L""].bypass, L"later");
}

TEST(ProxyOwnership, FailedSetterThatWroteRemainsOwned)
{
  auto backend = std::make_unique<FakeSettings>();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  os->fail_connection = L"VPN";
  os->fail_after_write = true;
  EXPECT_FALSE(Call(plugin, "StartProxy", StartArguments()));
  os->fail_connection = L"never";
  EXPECT_TRUE(Call(plugin, "StopProxy"));
  EXPECT_EQ(os->settings[L""].server, L"original:8080");
  EXPECT_EQ(os->settings[L"VPN"].server, L"vpn:8080");
}

TEST(ProxyOwnership, FailedCleanupBlocksSuccessorAndIsRetried)
{
  auto backend = std::make_unique<FakeSettings>();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  EXPECT_TRUE(Call(plugin, "StartProxy", StartArguments()));
  os->fail_connection = L"VPN";
  EXPECT_FALSE(Call(plugin, "StopProxy"));
  EXPECT_FALSE(Call(plugin, "StartProxy", StartArguments()));
  os->fail_connection = L"never";
  EXPECT_TRUE(Call(plugin, "StopProxy"));
  EXPECT_EQ(os->settings[L"VPN"].server, L"vpn:8080");
}

TEST(ProxyOwnership, FailedReadAndNotificationRemainVisibleUntilRetry)
{
  auto backend = std::make_unique<FakeSettings>();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  EXPECT_TRUE(Call(plugin, "StartProxy", StartArguments()));
  os->fail_read = true;
  EXPECT_FALSE(Call(plugin, "StopProxy"));
  os->fail_read = false;
  os->notify_ok = false;
  EXPECT_FALSE(Call(plugin, "StopProxy"));
  EXPECT_FALSE(Call(plugin, "StartProxy", StartArguments()));
  os->notify_ok = true;
  EXPECT_TRUE(Call(plugin, "StopProxy"));
}

TEST(ProxyPlugin, UnknownMethodIsNotImplemented)
{
  ProxyPlugin plugin;
  bool not_implemented = false;
  plugin.HandleMethodCall(
      MethodCall("unknown", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          nullptr, nullptr, [&not_implemented]() { not_implemented = true; }));

  EXPECT_TRUE(not_implemented);
}

TEST(ProxyPlugin, StartProxyRejectsMissingArguments)
{
  ProxyPlugin plugin;
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("StartProxy",
                 std::make_unique<EncodableValue>(EncodableMap())),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string& message,
                        const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, StartProxyRejectsInvalidPort)
{
  ProxyPlugin plugin;
  std::string error_code;
  EncodableMap arguments = {
      {EncodableValue("port"), EncodableValue(70000)},
      {EncodableValue("bypassDomain"), EncodableValue(EncodableList())}};

  plugin.HandleMethodCall(
      MethodCall("StartProxy",
                 std::make_unique<EncodableValue>(std::move(arguments))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string& message,
                        const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, StartProxyRejectsNonStringBypassDomain)
{
  ProxyPlugin plugin;
  std::string error_code;
  EncodableList bypass_domain = {EncodableValue("localhost"),
                                 EncodableValue(1)};
  EncodableMap arguments = {{EncodableValue("port"), EncodableValue(7890)},
                            {EncodableValue("bypassDomain"),
                             EncodableValue(std::move(bypass_domain))}};

  plugin.HandleMethodCall(
      MethodCall("StartProxy",
                 std::make_unique<EncodableValue>(std::move(arguments))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string& message,
                        const EncodableValue* details) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, ConditionalStopSucceedsWithoutApplyingAProxy)
{
  ProxyPlugin plugin;
  bool succeeded = false;
  EncodableMap arguments = {
      {EncodableValue("onlyIfNeeded"), EncodableValue(true)}};
  plugin.HandleMethodCall(
      MethodCall("StopProxy", std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          [&succeeded](const EncodableValue* value)
          { succeeded = value != nullptr && std::get<bool>(*value); }, nullptr,
          nullptr));

  EXPECT_TRUE(succeeded);
}

TEST(ProxyPlugin, StopProxyRejectsInvalidConditionalFlag)
{
  ProxyPlugin plugin;
  std::string error_code;
  EncodableMap arguments = {
      {EncodableValue("onlyIfNeeded"), EncodableValue("true")}};
  plugin.HandleMethodCall(
      MethodCall("StopProxy", std::make_unique<EncodableValue>(arguments)),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string&,
                        const EncodableValue*) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "bad_args");
}

TEST(ProxyPlugin, RestoresTheSystemProxyOnlyWhenTheSessionReallyEnds)
{
  EXPECT_TRUE(ProxyPlugin::IsSessionEnding(WM_ENDSESSION, TRUE));
  // A cancelled shutdown reports itself through the same message, and acting on
  // it would strip the proxy from a session that goes on running.
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_ENDSESSION, FALSE));
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_QUERYENDSESSION, TRUE));
  EXPECT_FALSE(ProxyPlugin::IsSessionEnding(WM_CLOSE, TRUE));
}

}  // namespace test
}  // namespace proxy
