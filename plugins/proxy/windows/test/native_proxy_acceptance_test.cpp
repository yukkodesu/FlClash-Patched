#include <windows.h>

#include <WinInet.h>
#include <flutter/method_result_functions.h>
#include <gtest/gtest.h>

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>

#include "proxy_plugin.h"

namespace proxy
{
namespace
{
using Snapshot = std::map<std::wstring, ProxySettings>;

std::string EnvironmentValue(const char* key)
{
  const DWORD size = GetEnvironmentVariableA(key, nullptr, 0);
  if (size == 0) return {};
  std::string value(size, '\0');
  const DWORD length = GetEnvironmentVariableA(key, value.data(), size);
  if (length == 0 || length >= size) return {};
  value.resize(length);
  return value;
}

bool EnvironmentEquals(const char* key, const char* expected)
{
  return EnvironmentValue(key) == expected;
}

std::string JsonString(const std::wstring& wide)
{
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                       static_cast<int>(wide.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string value(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      value.data(), size, nullptr, nullptr);
  std::ostringstream output;
  output << '"';
  for (const unsigned char character : value)
  {
    if (character == '\\' || character == '"')
      output << '\\' << character;
    else if (character < 0x20)
    {
      constexpr char hex[] = "0123456789abcdef";
      output << "\\u00" << hex[character >> 4] << hex[character & 15];
    }
    else
      output << character;
  }
  output << '"';
  return output.str();
}

std::string JsonSnapshot(const Snapshot& snapshot)
{
  std::ostringstream output;
  output << '{';
  bool first = true;
  for (const auto& item : snapshot)
  {
    if (!first) output << ',';
    first = false;
    output << JsonString(item.first) << ":{\"flags\":" << item.second.flags
           << ",\"server\":" << JsonString(item.second.server)
           << ",\"bypass\":" << JsonString(item.second.bypass) << '}';
  }
  output << '}';
  return output.str();
}

bool Invoke(ProxyPlugin& plugin, const std::string& method, int port = 7890)
{
  flutter::EncodableMap arguments;
  if (method == "StartProxy")
  {
    arguments = {
        {flutter::EncodableValue("port"), flutter::EncodableValue(port)},
        {flutter::EncodableValue("bypassDomain"),
         flutter::EncodableValue(
             flutter::EncodableList{flutter::EncodableValue("meow-owned")})}};
  }
  bool success = false;
  plugin.HandleMethodCall(
      flutter::MethodCall<flutter::EncodableValue>(
          method, std::make_unique<flutter::EncodableValue>(arguments)),
      std::make_unique<flutter::MethodResultFunctions<>>(
          [&success](const auto* value)
          { success = value && std::get<bool>(*value); }, nullptr, nullptr));
  return success;
}

class NativeFixture
{
 public:
  ProxySettingsBackend& backend;
  Snapshot baseline;
  std::map<std::string, std::string> evidence;
  bool armed = false;
  explicit NativeFixture(ProxySettingsBackend& value) : backend(value) {}
  bool Capture(Snapshot& result)
  {
    std::vector<std::wstring> connections;
    if (!backend.Connections(connections)) return false;
    for (const auto& connection : connections)
    {
      ProxySettings settings;
      if (!backend.Read(connection, settings)) return false;
      result[connection] = settings;
    }
    return true;
  }
  bool InstallForeign(int port, const std::wstring& bypass)
  {
    const ProxySettings settings{PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY,
                                 L"127.0.0.1:" + std::to_wstring(port), bypass};
    for (const auto& item : baseline)
      if (!backend.Write(item.first, settings, kFlags | kServer | kBypass))
        return false;
    return backend.Notify();
  }
  ~NativeFixture()
  {
    if (!armed) return;
    bool restored = true;
    for (const auto& item : baseline)
      restored =
          backend.Write(item.first, item.second, kFlags | kServer | kBypass) &&
          restored;
    restored = backend.Notify() && restored;
    Snapshot after;
    restored = Capture(after) && restored;
    EXPECT_TRUE(restored);
    EXPECT_EQ(JsonSnapshot(after), JsonSnapshot(baseline));
    evidence["finalBaseline"] = JsonSnapshot(after);
    evidence["baseline"] = JsonSnapshot(baseline);
    evidence["outcome"] =
        ::testing::Test::HasFailure() ? "\"failed\"" : "\"passed\"";
    std::ostringstream output;
    output << "{\"platform\":\"windows\"";
    for (const auto& item : evidence)
      output << ",\"" << item.first << "\":" << item.second;
    output << "}\n";
    std::cout << output.str();
    const auto path = EnvironmentValue("FLCLASH_MEOW_PROXY_EVIDENCE_PATH");
    if (!path.empty())
    {
      std::ofstream file(path);
      file << output.str();
      EXPECT_TRUE(file.good());
    }
  }
};

TEST(ProxyNativeAcceptance, RestoresOnlyOwnedRealWinInetSettings)
{
  if (!EnvironmentEquals("GITHUB_ACTIONS", "true") ||
      !EnvironmentEquals("RUNNER_ENVIRONMENT", "github-hosted") ||
      !EnvironmentEquals("FLCLASH_MEOW_PROXY_NATIVE_ACCEPTANCE", "1"))
  {
    GTEST_SKIP() << "Requires an opted-in disposable GitHub runner";
  }
  auto backend = CreateProxySettingsBackend();
  auto* os = backend.get();
  ProxyPlugin plugin(std::move(backend));
  NativeFixture fixture(*os);
  ASSERT_TRUE(fixture.Capture(fixture.baseline));
  fixture.armed = true;
  ASSERT_TRUE(fixture.InstallForeign(8088, L"foreign-original"));
  Snapshot before;
  ASSERT_TRUE(fixture.Capture(before));
  fixture.evidence["before"] = JsonSnapshot(before);
  ASSERT_TRUE(Invoke(plugin, "StopProxy"));
  Snapshot inactive;
  ASSERT_TRUE(fixture.Capture(inactive));
  EXPECT_EQ(JsonSnapshot(inactive), JsonSnapshot(before));
  ASSERT_TRUE(Invoke(plugin, "StartProxy"));
  Snapshot installed;
  ASSERT_TRUE(fixture.Capture(installed));
  fixture.evidence["installed"] = JsonSnapshot(installed);
  ASSERT_TRUE(Invoke(plugin, "StopProxy"));
  Snapshot after;
  ASSERT_TRUE(fixture.Capture(after));
  fixture.evidence["after"] = JsonSnapshot(after);
  EXPECT_EQ(JsonSnapshot(after), JsonSnapshot(before));
  ASSERT_TRUE(Invoke(plugin, "StartProxy"));
  ASSERT_TRUE(fixture.InstallForeign(8089, L"foreign-later"));
  Snapshot later;
  ASSERT_TRUE(fixture.Capture(later));
  fixture.evidence["laterWriter"] = JsonSnapshot(later);
  plugin.HandleWindowProc(nullptr, WM_ENDSESSION, TRUE, 0);
  Snapshot final_state;
  ASSERT_TRUE(fixture.Capture(final_state));
  fixture.evidence["afterLaterWriter"] = JsonSnapshot(final_state);
  EXPECT_EQ(JsonSnapshot(final_state), JsonSnapshot(later));
  EXPECT_FALSE(Invoke(plugin, "StartProxy", 7891));
}
}  // namespace
}  // namespace proxy
