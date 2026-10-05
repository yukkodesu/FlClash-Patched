[English](README.md)

# FlClash-Meow

基于 [FlClash-Patched](https://github.com/chenx-dust/FlClash-Patched) 和 [FlClash](https://github.com/chen08209/FlClash) 的桌面代理客户端，通过嵌入式 Rust host 使用自有 [meow-rs fork](https://github.com/yukkodesu/meow-rs)。

产品只使用 meow-rs 内核。目标矩阵为 Windows、macOS、Linux，各包含 x64 和 ARM64。保留的 Android/iOS 源码不属于构建或发布范围。客户端、数据目录、Helper 和更新源使用独立的 FlClash-Meow 标识。

当前为开发中的桌面迁移版本，FlClash-Meow 正式包尚未发布。构建成功和普通代理检查不能证明安装或原生 TUN 清理已通过。请查看[验收矩阵及对应源码、运行记录](docs/specs/meow-desktop-acceptance.md)，区分已完成与待验证的项目；后续发布包使用[本 fork 的 Releases](https://github.com/yukkodesu/FlClash-Patched/releases)。

## 功能与差异

保留配置和订阅管理、Material You 主题、系统代理、托盘、快捷键及开机启动。运行能力以固定版本的 host 为准，不承诺 mihomo 功能兼容。

| 范围 | 产品行为 |
|---|---|
| 配置 | 保留导入原文，应用前检查派生配置。不支持的协议或选项、未知字段及不安全的 provider 路径阻止应用，不静默删除节点或规则。自定义 direct 别名会被拒绝，因为现有适配器始终暴露 DIRECT。 |
| 代理与 provider | 接入当前 meow 构建支持的代理组、节点选择、测速及 provider 查询/刷新。未提供的订阅信息显示为未知。 |
| 运行修改 | 模式、日志级别动态修改；其他配置变更受控重启。可查询日志和实际绑定的代理、DNS、controller 地址。 |
| 统计与连接 | 流量统计包括内核全部流量，不提供仅代理统计。连接快照和关闭操作覆盖 TCP；不提供精确 UDP 连接明细、节点累计流量或完整请求历史事件。内存指标取自实际进程，无法取得时明确显示不可用。 |
| 认证 | meow 始终豁免来源地址 127.0.0.1/32 和 ::1/128，空 skip-auth-prefixes 也不能移除。配置检查会提示此差异；监听 loopback 不等于认证本机程序。 |
| TUN | Fake-IP 范围捕获与实验性 global 路由捕获不同。IPv6 捕获需要相应 global 配置及平台验证。开关开启或 Helper 就绪均不能证明正在捕获流量。不支持的 mihomo stack、strict-route、route-address、endpoint-independent-nat 开关已移除。 |

不接入 Tailscale/ZeroTier/EasyTier 控制、AGE 密钥操作、Go GC/goroutine/pprof 诊断、DNS 逐次查询追踪、provider 侧载、手动 geodata 热替换事务及独立内核/外部 UI 更新器。可选 external-controller 默认关闭，与客户端 IPC 独立。完整差异见[能力与配置策略](docs/specs/meow-desktop-client.md#6-功能取舍)。

## 源码构建

从所需 FlClash-Meow 客户端版本的 checkout 开始。core/meow-rs 的来源为 yukkodesu/meow-rs，版本由客户端 gitlink 固定；不要直接替换为内核仓库最新分支。

~~~bash
git submodule update --init --recursive
git ls-tree HEAD core/meow-rs
flutter pub get
~~~

需要 Flutter **3.47.6**、Git、rustup/Cargo、CMake、原生 C/C++ 编译器、Python 和 libclang。内核固定 Rust **1.98.1**；独立的 plugins/rust_api/rust 工具库固定 **1.99.0**。从相应 crate checkout 运行 Cargo，以使用其工具链固定版本。libclang 自动查找失败时，将 LIBCLANG_PATH 设为其共享库所在目录。

| 构建系统 | 额外依赖 |
|---|---|
| Windows | Visual Studio 的“使用 C++ 的桌面开发”、对应 MSVC 工具和 Windows SDK、NASM、Inno Setup。host 嵌入对应架构的官方 Wintun DLL；MEOW_WINTUN_DLL 可指定已验证的本地文件。 |
| Linux | Ninja、Clang、pkg-config、GTK3、libayatana-appindicator、libsecret 开发包，以及所选安装包格式所需工具。 |
| macOS | Xcode/命令行工具、原生 LLVM/libclang，以及用于 DMG 打包的 Node/npm 和 appdmg。 |

在目标操作系统上构建。架构参数为 amd64 或 arm64；Windows/Linux 需要架构匹配的原生构建机。按目标选择一条命令：

~~~bash
dart setup.dart windows --arch amd64
dart setup.dart linux --arch arm64
dart setup.dart macos --arch amd64
dart setup.dart macos --arch arm64
~~~

打包会构建 Rust host 和独立工具库，再将 host 最终哈希嵌入 Windows/Linux Helper 并记录 manifest。打包时保持两个原生 build_assets hook 开启。桌面构建不依赖 Go 或 mihomo。详细依赖、直接构建产物及检查命令见 [.agents/project.md](.agents/project.md) 和 [.agents/commands.md](.agents/commands.md)；[原生 CI](.github/workflows/build.yaml) 覆盖六种目标组合。

## 来源与许可证

客户端源自 FlClash 与 FlClash-Patched，遵循 [GPL-3.0](LICENSE)。嵌入式内核源自 [meow-rs](https://github.com/meow-rs/meow-rs)，遵循其 [MIT 许可证](https://github.com/meow-rs/meow-rs/blob/HEAD/LICENSE)。与客户端耦合的 Rust host 留在自有 meow-rs fork；随附依赖保留各自版权声明和许可证。
