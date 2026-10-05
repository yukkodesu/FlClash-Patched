# 基于 FlClash 的 meow-rs 单内核桌面客户端方案

- 日期：2026-10-05。
- 文档状态：本地方案已完成；尚未发布到 issue tracker。
- 产品范围：独立客户端 fork，仅使用 meow-rs；本期覆盖 Windows、macOS、Linux。
- 已确认决策：Rust host 留在自有 meow-rs fork；接受内核能力差异；不建设双内核兼容体系。
- 已确认测试 Seam：以现有 CoreController 为主要验收入口，复用必要的 IPC、生命周期和 Helper 契约测试。
- 代码调查基线：FlClash-Patched `42ebfa11`，meow-rs `3c27aca`（0.22.0），现有 mihomo 子模块 `f63b4a0a`。
- 本文定义后续实施要求；不表示 Rust host、客户端 fork 或桌面运行已完成。

## Problem Statement

用户希望获得一个沿用 FlClash 桌面交互、配置管理和系统集成体验，但完全使用 meow-rs 的独立客户端。现有客户端通过自定义 RPC 调用 Go wrapper，后者直接依赖自有 mihomo fork 的内部 Interface、配置模型和扩展 hook，无法通过替换内核可执行文件实现这一目标。

双内核产品会增加内核切换、能力分支、两套配置生成、切换回滚和双份回归验证。用户已选择独立 fork，以 meow-rs 实际能力定义产品行为，减少长期维护负担。

meow-rs 与 mihomo 在代理协议、配置字段、热更新、TUN 路由、统计和诊断上存在差异。本期需要让这些差异成为明确的产品行为，而不是加载成功后的隐性失效。用户不要求扩展 meow-rs 来追平 mihomo 或当前自有 fork 的功能。

## Solution

创建独立桌面客户端 fork，保留 Flutter UI、配置管理、系统代理、托盘、快捷键、桌面进程生命周期和特权启动能力，将 Go wrapper 替换为独立进程形式的 Rust host。客户端只分发和启动这一种内核，不提供内核选择入口。

Rust host 作为独立 Module 留在自有 meow-rs fork，通过其现有 crate 实现配置加载、代理运行、查询和操作，并提供客户端所需的控制 Interface。客户端继续经 CoreController 和本地 IPC 使用内核；运行不依赖用户开放 external-controller，也不通过另起 meow 子进程再转发 REST 来实现。

产品保留 meow-rs 已有且本期验证通过的能力，调整有行为差异的设置，移除未支持的功能入口。配置导入和应用均有可见的兼容检查结果。桌面普通代理先打通，随后完成同一方案内的 TUN、Helper 和安装包验证。

交付物包括两个 fork 的实施改动、Rust host 可执行文件、三个桌面平台的客户端安装包、能力与配置差异说明、自动化契约测试和真实平台验收记录。

## User Stories

1. As a desktop user, I want 一个只使用 meow-rs 的独立客户端, so that 日常使用无需理解或选择另一种内核。
2. As a desktop user, I want 在 Windows、macOS 和 Linux 上安装客户端, so that 我可以在常用桌面系统使用一致的基本操作。
3. As a desktop user, I want 新客户端拥有独立的数据目录和系统标识, so that 安装和卸载不会覆盖现有 FlClash 的资料或后台注册。
4. As a desktop user, I want 查看客户端、内核及控制协议版本, so that 我能准确报告运行环境。
5. As a desktop user, I want 查看当前构建支持的功能及限制, so that 我不会误认为所有 mihomo 功能都可用。
6. As a desktop user, I want 导入本地配置和订阅, so that 我可以使用 meow-rs 支持的节点和规则。
7. As a desktop user, I want 保留导入内容的原始副本, so that 配置转换或检查不会破坏订阅信息。
8. As a desktop user, I want 在应用前查看不支持的协议、规则和设置, so that 我能修正配置并理解差异。
9. As a desktop user, I want 对会改变路由、监听或捕获范围的兼容问题得到阻止应用的错误, so that 客户端不会在关键配置失效时仍显示运行成功。
10. As a desktop user, I want 查看最终生效配置和检查警告, so that 我能理解客户端生成的运行行为。
11. As a desktop user, I want 配置失败后继续使用上一份有效配置或明确知道恢复失败, so that 我不会在不知情时使用空配置或默认直连。
12. As a desktop user, I want 保存代理组选择并在再次应用时恢复有效选择, so that 重启后不必重复选择节点。
13. As a desktop user, I want 开关代理而仍能管理配置和查看内核状态, so that 停止代理不等于退出整个应用。
14. As a desktop user, I want 看到代理监听就绪后再显示代理运行成功, so that 运行状态能反映实际可用性。
15. As a desktop user, I want 连续开关和重启操作最终服从最新请求, so that 快速操作不会留下多个内核或错误状态。
16. As a desktop user, I want 内核崩溃和 IPC 断开得到清晰反馈并可重启恢复, so that 我能判断和修复连接问题。
17. As a desktop user, I want 浏览代理组和切换节点, so that 我能选择当前需要的代理路径。
18. As a desktop user, I want 对支持的自动组切回自动选择, so that 手动固定节点后仍能恢复内核自身策略。
19. As a desktop user, I want 测速可显示进度、取消和错误, so that 内核超时或重启不会被误记成节点不可达。
20. As a desktop user, I want 查看实时及累计流量的实际统计口径, so that 我知道 DIRECT 流量是否包含在数值中。
21. As a desktop user, I want 查看真实连接并关闭一个或全部可管理连接, so that 我可以排查和结束流量。
22. As a desktop user, I want 连接列表明确说明 UDP 展示限制, so that 我不会把空列表当作完全没有流量。
23. As a desktop user, I want 查看日志并按等级筛选, so that 我可以排查配置、监听器和代理错误。
24. As a desktop user, I want 日志洪泛时界面仍能响应且状态变化可确认, so that 日志不会阻塞控制或让运行状态长期失真。
25. As a desktop user, I want 查询和刷新支持的代理及规则 provider, so that 我能更新运行配置所依赖的数据。
26. As a desktop user, I want provider 更新失败时收到真实结果并保留内核已有的有效数据, so that 网络错误不会表现为成功更新。
27. As a desktop user, I want 修改模式和日志级别立即生效, so that 我能使用内核现有的动态控制能力。
28. As a desktop user, I want 需要重启的配置修改有明确提示并恢复原先的运行意图, so that 我理解短暂中断且不必手动重新开启代理。
29. As a desktop user, I want 使用系统代理和本地监听认证, so that 应用流量可以经代理转发并遵循我的访问设置。
30. As a desktop user, I want TUN 捕获范围、DNS 和 IPv6 行为明确可见, so that 我知道哪些流量会进入内核。
31. As a desktop user, I want 特权启动不可用时仍可使用普通代理并看到实际 TUN 状态, so that 授权问题不会阻止其他代理功能。
32. As a desktop user, I want 托盘、快捷键及开机启动继续工作, so that 我能延续桌面使用习惯。
33. As a desktop user, I want 正常退出释放代理、内核和网络资源, so that 客户端不会留下后台进程或错误的系统设置。
34. As a desktop user, I want 卸载只处理新客户端自身的注册和文件, so that 现有 FlClash 和其他软件不会受影响。
35. As a desktop user, I want 客户端更新使用新产品自己的发布源, so that 更新不会装回 FlClash 或 mihomo 版本。
36. As a maintainer, I want Rust host 的客户端耦合集中在独立 Module, so that 合入 meow-rs 上游时容易定位需要适配的改动。
37. As a maintainer, I want 从干净环境构建桌面版时不再需要 Go 或 mihomo, so that 依赖和发布流程与单内核产品一致。
38. As a maintainer, I want 固定上游提交并通过统一的外部行为测试验证升级, so that 上游变化造成的回归在发布前可见。
39. As a maintainer, I want 平台和架构验收状态可追踪, so that 未验证的 TUN 或安装行为不会被宣传为已支持。

## Implementation Decisions

### 1. 产品与仓库归属

- 客户端 fork 负责 UI、配置编辑与转换、数据持久化、桌面集成、构建、安装包和发布。
- meow-rs fork 负责内核以及一个独立 Rust host crate。该 crate 保留在自有 fork，不向 meow-rs 上游提交。
- 定期合入 meow-rs 上游，并固定客户端所使用的 fork 提交。FlClash 上游的 UI 和通用修复按需挑选，不把完整跟随 FlClash 的每次发布作为约束。
- 实施在新产品的仓库中完成。现有 FlClash-Patched 仅作为来源；本方案文档的保存不授权将其现有运行实现原地替换或删除。
- 新产品需具有独立的应用标识、安装位置、数据目录、IPC 命名空间、Helper 注册和更新源。最终产品名在建立 fork 时确定；这些标识必须在安装包验收前固定。
- 支持与原客户端同时安装；两个应用同时占用相同代理端口或系统路由时应报告冲突，不自动停止或卸载另一个应用。

### 2. Module 与 Interface

- 保留 CoreController 作为 UI/provider 使用的主要 Interface 和测试 Seam。其后仍使用现有的桌面 composition、RPC、IPC transport、生命周期和 process lease。
- Rust host 直接嵌入 meow-rs 的 crate，单个内核进程处理 IPC 和代理运行。禁止用额外的 meow 子进程形成第二份进程所有权。
- Rust host 对外承担初始化、身份与能力查询、配置检查与应用、代理运行启停、代理操作、连接操作、统计查询、provider 操作、日志订阅和退出清理。
- host 内部按协议、配置适配、运行资源管理、观测转换划分职责，避免一个 handler 复制整套 CLI 启动实现。
- meow-app 当前并未导出完整可嵌入的应用运行 Interface。优先复用现有公共 Interface；确需抽取的运行编排应集中、最小化，不趁接入增加代理协议或诊断能力。
- 现有 rust_api 的 IPC primitives、脚本和快捷键继续留在 Flutter 应用一侧，Rust host 独立构建和运行。
- 不新增多内核注册表、通用 backend factory、内核选择设置或内核切换状态机。

### 3. 控制协议

- 复用现有请求 id、method、arguments 和响应 id、result、error 的 envelope；arguments、result、事件列表只进行一次结构化 JSON 编码。
- 复用四字节小端长度前缀和现有 frame 大小限制，遵守已有分包、断开、写入背压和部分 frame 恢复约束。
- 初始化握手返回 meow 内核版本、host 版本、内核提交、控制协议版本及能力描述。握手完成后才视为控制就绪；控制就绪与代理监听就绪是两个不同事实。
- 错误区分参数错误、配置不兼容、操作不支持、运行未就绪、传输失败和内部错误。未知方法与已知但不支持的操作必须可区分，不返回伪造的成功、空字符串或零值来掩盖缺失能力。
- 保留仍被客户端使用的领域 DTO，按 meow 实际返回进行 Adapter 转换。移除只服务于 Go 或 mihomo 扩展的调用，不要求复制完整旧方法集合。
- 客户端已确认退出后，不再接受新调用；计划退出中的未完成调用采用现有的取消语义。异常断开则失败所有未完成调用。
- 控制只走本地 IPC。external-controller 是单独的可选功能，默认关闭，开启时沿用已支持的绑定和认证行为，不作为客户端启动的前提。

### 4. 生命周期与运行资源

- 桌面内核进程所有权继续属于 DesktopCoreLifecycle，使用现有 applied、coalesced、superseded 结果和最新意图收敛行为。UI、provider 和 Rust host 不成为第二个进程 owner。
- Rust host 管理进程内部的 Tunnel、DNS、listener、provider 后台任务及其释放顺序。Core 启动先建立控制能力，不自动打开代理监听器。
- 开启代理时先应用已通过检查的配置，再建立所需监听器；必要的监听器和 TUN 准备失败必须回报实际结果。关闭代理停止代理监听和其网络资源，保留控制进程以支持配置管理。
- 模式和日志级别使用 meow 已有动态能力。其他运行配置修改在本期统一标记为需要受控重启，不承诺完整热更新。客户端通过现有生命周期模块完成重启、重新初始化、重新应用配置和恢复最新运行意图。
- 配置或重启请求有操作 generation；只有当前操作可以提交配置、发布运行结果和恢复运行意图。较旧测速、后台刷新结果和事件不得覆盖新会话。
- 同一时间不得存在两个生效的 listener/TUN generation。新 generation 必须等待旧资源释放确认；lwIP 的 process-global 状态也遵循原有 teardown 完成约束。
- process lease 的退出未确认时继续持有所有权，阻止启动第二份内核。CoreController.close 是终态操作，仅用于应用退出，普通重启不调用它。
- 主应用 IPC 真正断开或收到正常终止信号时，host 释放自身网络资源并退出。主应用暂时停止读取不等同于断开，不用日志流背压触发无限重启。
- 退出清理由现有 SystemExitCoordinator 统一编排，涵盖系统代理、桌面资源、host 和进程退出，并保留幂等、错误继续清理及 watchdog 行为。

### 5. 配置、兼容检查与持久化

- 保留原始配置和订阅内容；运行配置是派生结果。meow 的 typed config 或运行时序列化结果不得回写覆盖原始内容。
- 调整客户端配置模型和 UI 为 meow 实际支持的字段。已有覆写、脚本和 provider 路径处理可复用，但其输出也必须通过同一兼容检查。
- 检查结果包含严重性、对象定位、原因和处理建议；对象定位可指向节点、组、规则、provider 或配置键，不仅提供整段日志。
- 不支持的节点协议、规则、组引用，以及会改变路由、监听、认证、DNS 或捕获范围的配置问题属于阻止应用的错误。本期不提供自动删节点、删规则后继续运行的部分加载模式。
- 仅影响未提供的诊断或性能选项、且不改变承诺行为的字段可作为警告忽略；忽略项在应用前可见并记入生效配置说明。没有已定义处理策略的未知键默认阻止应用。代理节点及其嵌套选项也必须检查，不能只检查顶层键。
- 使用 meow 已有严格解析能力辅助检查，并在 host/客户端补充明确的字段策略；严格解析不等于所有不支持字段均已被发现。节点或规则被跳过不允许成为无条件成功。
- meow 支持的组名称、顺序、自动选择及手动选择语义转为客户端领域数据。保存的选择只有在目标组和节点仍然有效时恢复，无效选择由内核策略处理并报告。
- 初始化允许没有已选 profile，此时保持明确的空闲状态。用户提供的无效 profile 不得悄悄回落成默认直连。
- 应用前先检查候选配置，检查失败不覆盖当前生效配置。必须重启才能完成的应用保留上一份有效配置，以便新配置启动失败时尝试恢复。
- 候选运行失败后，恢复上一份有效配置并遵循最新运行意图；恢复也失败时进入明确失败状态，不宣称仍在使用旧配置。用户后续的停止意图优先于恢复运行。
- provider 缓存和其他写入限制在新产品自己的数据范围内；相对路径按声明的基准目录解析，导入内容不得扩大特权读写范围。
- 新产品使用独立 provider、DNS/fake-IP 和 geodata 缓存。复用 meow 已支持的资源格式和更新机制，不移植 mihomo 私有 matcher cache 或扩展格式。
- 不自动迁移 FlClash 的整个数据库。用户通过配置和订阅导入开始使用；导入过程不会修改来源应用的数据。

### 6. 功能取舍

能力声明是当前 host 构建的事实描述，供 UI 和校验器使用，不构成第二套可插拔内核框架。平台或编译 feature 缺失的功能必须声明不可用。

| 功能 | 本期决策 | 可见行为 |
|---|---|---|
| 已支持代理协议、规则及代理组 | 接入 meow 原有能力 | 不扩展协议集合；受构建 feature 和配置检查约束 |
| 代理组查询、选节点、自动组解除固定 | 接入 | 使用 meow 的选择语义；保留确定的组顺序 |
| 测速 | 接入 | 有进度、取消和真实错误；传输失败不记录为节点不可达 |
| 模式、日志级别 | 动态修改 | 成功后查询与实际行为一致 |
| 其他运行配置修改 | 受控重启 | 明确短暂中断，重新应用配置并恢复运行意图 |
| 系统代理、托盘、快捷键、开机启动 | 保留桌面体验 | 新产品使用独立注册和状态 |
| 本地监听认证、LAN 暴露 | 接入已支持的配置 | 保留实际认证语义，不静默接受忽略的字段 |
| 实时与累计流量 | 接入 | 展示 meow 的统计口径；内核重启后的累计周期明确 |
| 仅统计代理流量 | 移除该选项 | 不用全量流量伪装成代理专属统计 |
| 节点累计流量 | 移除 | 不通过采样连接列表估算成精确统计 |
| 连接快照、关闭单条/全部连接 | 接入已支持操作 | 明确 TCP 展示范围；不承诺 UDP 连接明细 |
| 精确的新请求历史事件 | 不接入 | 使用实际连接快照，不把轮询差分称为完整请求历史 |
| 日志 | 接入 | 有限缓存、等级筛选、订阅释放与背压控制 |
| 内核内存 | 接入可取得的实际进程指标 | 使用明确名称，不把 RSS 称为 Go heap；无法取得时显示不可用 |
| Go GC、goroutine 数、pprof | 移除 | 不显示无意义的 Rust 替代数值 |
| provider 列表、详情与刷新 | 接入已支持操作 | 刷新错误真实可见，状态最终可查询 |
| provider 侧载专用操作 | 不接入 | 不为兼容旧 wrapper 增加内核专用写入能力 |
| provider subscriptionInfo | 不承诺 | 内核未提供时显示未知；客户端自己取得的订阅信息须注明来源 |
| DNS 逐次查询追踪 | 移除 | 不把 DNS 缓存快照当作发起来源、耗时和上游追踪 |
| Tailscale、ZeroTier、EasyTier 控制 | 移除 | 配置中出现未支持节点时阻止应用 |
| 手动 geodata 热替换事务 | 不接入 | 仅使用 meow 已有资源加载和更新能力 |
| AGE 专属配置和密钥操作 | 不接入 | 导入时明确不支持，不复制现有 Go 加密功能 |
| 可选 external-controller | 接入 meow 已支持范围 | 与客户端 IPC 独立，默认关闭 |
| 内核自升级与外部 UI 自动升级 | 不接入 | host 随客户端发布，保持版本和完整性匹配 |

### 7. TUN 与系统集成

- 本期包含桌面 TUN 的接入和验证，使用 meow 已有设备、lwIP、路由和 DNS能力。设置只展示当前平台及构建实际支持的选项。
- 区分 fake-IP 范围捕获和 global 路由捕获。原客户端的 auto-route 布尔值不得不加说明地映射为相同捕获行为。完整捕获选项映射到 meow 的 global 模式，并标明其上游实验状态。
- 移除无实际实现的 stack 选择、strict-route、route-address 和 endpoint-independent-nat 等设置，不保留看似可用的 mihomo 开关。
- IPv6 捕获需要已支持的 global 模式、设备 IPv6 地址及平台验证。仅配置 ipv6 为 true 不表示所有 IPv6 流量已进入 TUN。
- Windows 打包或按 meow 已有机制提供对应架构的 Wintun；macOS、Linux 使用现有特权启动模式。TUN 设备名称和可定位资源使用新产品标识。
- 系统代理、路由和 DNS 修改只管理本产品实际创建或修改的资源。正常停止、重启、退出和失败恢复必须考虑资源清理。
- 不假定 Rust Drop 在强制终止或 abort 后一定执行。真实平台测试涵盖异常进程结束后的残留检测和恢复；恢复不能覆盖其他应用后来修改的系统设置。无法完成恢复时显示具体失败，而非隐藏问题。
- TUN 不可用不妨碍普通代理。UI 展示实际可用的运行模式；客户端不能仅凭 Helper 就绪或 TUN 开关为 true 宣称 TUN 正在捕获流量。
- 对未通过验收的特定平台、架构或 TUN 模式，发布包将该能力标为不可用或实验，不能用其他平台的通过记录替代。

### 8. Helper 与进程完整性

- Windows/Linux Helper 继续只启动安装包中固定位置的单个 host。替换可信文件和编译时 hash，不增加多内核名单、用户指定 executable 路径或自由命令执行。
- 继续先构建 host、计算最终产物 SHA256、再构建嵌入该 hash 的 Helper 和 manifest。Debug、Profile、Release 遵循一致的完整性契约。
- 保留 session-scoped stop、32 位小写十六进制 session ID、Windows named-pipe peer PID 验证、Unix socket 权限和 Linux peer UID 检查。新产品的命名空间在客户端、host 和 Helper 间一致。
- /start 只有在旧进程退出确认后才启动新进程；停止未确认时禁止 direct fallback 与旧进程并存。允许 fallback 的失败必须属于已经确认没有 Helper-managed 进程的场景。
- Helper 不可用或允许降级的启动失败走普通 direct launch。特权能力实际不可用时，生成可运行的普通代理配置，禁止未经隔离的 TUN 设置反过来使普通代理也启动失败。
- 保留 Linux cgroup 与 Windows Job Object 的子进程归属。Linux 特权 host 的文件写入需保持归属正确，不能留下普通用户以后无法编辑的缓存或配置。
- Helper 协议仅在 wire contract 实际变化时升级版本；产品命名、固定 host 文件及 hash 的调整不构成增加多内核协议的理由。旧产品的 Helper 不能被识别为本产品可用的 Helper。

### 9. 构建、发布与同步维护

- 客户端固定引用 meow-rs fork 的具体提交，构建独立 Rust host；开发机上的相邻 checkout 不是正式构建依赖。
- 新客户端移除 Go wrapper、mihomo 子模块和桌面 Go build/vet/test 步骤。保留已有 Rust 工具库、Helper 及其构建路径，避免将三者误合成一个运行进程。
- 构建缓存纳入 Rust workspace、Cargo lockfile、所选 feature、工具链、目标架构、host 来源提交、构建设置及最终输出状态。失败构建不得覆盖上次有效产物，也不能悄悄打包旧内核。
- 显式列出 BoringSSL、lwIP 和 QUIC 等依赖所需的 C/C++、CMake 及目标平台工具链。Windows 使用 meow 支持的 Rust MSVC 目标，不假定现有 Go 构建工具链可替代它。
- 本期基础发布矩阵为 Windows x64/arm64、macOS x64/arm64、Linux x64/arm64。每个声明支持的目标都需对应打包和验收记录；额外的 CPU 指令集优化包不属于本期。
- 完成新产品的安装、卸载、开机启动、托盘、更新源和 macOS 签名/授权标识调整。保留原有开源许可证及必要归属，不在本期重新设计完整视觉品牌。
- 发布包同时固定客户端、host、内核和 Helper 的版本组合。内核更新通过客户端发布，不在安装后独立替换特权 host。
- meow 上游升级只适配 host 所依赖的 Interface 和已提供能力。未支持的功能继续保持明确差异，不借升级扩大本期范围。

## Testing Decisions

### 主要测试 Seam

用户已确认：CoreController 是主要测试 Seam。良好测试验证调用方可观察的结果、事件和运行行为，不绑定 host 内部分层、任务数量、私有类型或 handler 实现方式。

- 复用 CoreController 的现有可注入实现，验证 UI/provider 对成功、错误、取消和能力缺失的反应。
- 增加经 CoreController 调用真实 Rust host 的跨语言集成测试，覆盖 IPC 到代理运行的完整路径。仅 mock Interface 的测试不能证明 Rust host 已接入。
- 配置校验、错误类型、监听器启停和节点操作尽量在这一 Seam 验证。只有现有公开 Interface 无法观察的 wire framing、peer identity 和特权启动契约，继续使用必要的内部 Seam。
- 不为每个私有函数追加镜像式测试，也不建设与生产调用方式无关的另一套测试 Interface。

### 自动化行为与契约

1. 身份和协议：客户端与 host 版本兼容可初始化；不兼容版本、错误 peer 和未知方法得到明确失败；不支持功能不伪装成成功。
2. 配置：本期支持协议与 provider fixture 可应用；不支持的节点、嵌套选项、规则、认证或路由字段被定位；忽略警告可见；原始配置保持完整。
3. 配置提交：检查失败不影响有效配置；重启后的应用失败可恢复；恢复失败进入失败状态；后来的停止意图阻止恢复运行。
4. 代理运行：host 控制就绪时代理端口尚未开放；启动后通过 HTTP/SOCKS 的本地测试服务取得可预测响应；停止后监听关闭，配置操作仍可使用。
5. 操作收敛：快速开关、重复重启、重叠配置应用只兑现最新意图；停止未确认时不出现第二份内核；终态 close 幂等且不可重新启动。
6. 代理组：名称、顺序、有效选择恢复、无效选择处理、自动组固定与解除固定符合 meow 行为。
7. 测速：使用本地可控测试服务覆盖成功、节点超时、取消和 Core 断开；队列与探测预算有界；Core 故障不覆盖已有测速结果为节点不可达。
8. 连接和统计：通过真实传输校验统计口径与关闭操作；明确 UDP 展示范围；不以连接快照推算精确节点统计或请求历史。
9. provider：刷新成功与失败可观察，最终状态可查询；已有数据的保留遵循 meow 行为；取消和退出后无后台结果覆盖新会话。
10. 日志和事件：有限缓存、单事件与批事件解码、订阅释放、listener 异常隔离和压力下控制响应正确；bulk 不能挤出状态事件；发生溢出时最终状态可查询并收敛。
11. IPC：分片 frame、边界尺寸、错误 JSON、单次编码、并发请求关联、完整与部分写入背压、异常断开及计划关闭取消遵循现有契约。
12. Helper：固定文件/hash、session 归属、PID 验证、停止未确认、允许与禁止 fallback 的场景，以及新旧产品隔离。
13. 构建：工具链或输入变化使缓存失效，失败不破坏有效产物；manifest 和 Helper 对应最终包内 host；干净桌面构建不依赖 Go/mihomo。
14. 产品 UI：不支持功能无有效入口；能力、统计口径、兼容问题、重启要求和实际 TUN 状态表达正确。

### Prior Art

- 桌面生命周期、process lease、可替换 transport 和 RPC request correlation 的现有测试。
- CoreService composition、terminal close、协议 envelope 与事件 batch 的现有测试。
- CoreAction 重叠重启和 SystemExitCoordinator 退出序列测试。
- CoreManager、测速 provider 和 CoreStatusButton 的错误与状态反馈测试。
- setup build cache、manifest 和 Helper session/进程完整性测试。
- meow 的配置严格解析、组选择、delay、provider、DNS reload 和 TUN teardown 测试。

保留上述测试中仍适用的外部行为，将依赖 Go 源码的方法集合检查替换为 Dart/Rust 契约检查。Flutter 模型和 provider 使用 flutter test；Rust host、Helper 与 meow 使用各自匹配的 Rust 检查。

### 真实桌面验收

- 在三种桌面系统验证冷启动、配置导入、普通代理、托盘、快捷键、开机启动、更新路由、正常退出和安装卸载隔离。
- 对每个发布架构完成原生启动 smoke；涉及 OS 行为的结论来自对应系统，不从 Windows 的检查结果推导 macOS/Linux 已通过。
- 在可恢复的测试环境验证系统代理和本地认证，不让普通单元测试修改测试机的实际网络配置。
- TUN 覆盖 fake-IP 与 global 范围、IP literal、TCP/UDP、DNS、已声明 IPv6 行为、网卡变化、授权失败、重启和正常 teardown。
- 故障注入覆盖 host 崩溃、主应用异常退出、Helper 退出、部分清理失败、残留路由/DNS 检测及恢复。Windows named-pipe、SCM、Job Object，Linux systemd/setuid，以及 macOS 特权启动分别实测。
- 真实远端节点只作为人工、明确选择的 smoke，不把私有订阅或节点凭据写入 fixture，不使 CI 依赖公网代理。

### 发布验收门槛

- 新产品包中仅有 Rust host 内核，构建和运行均不引用 Go wrapper 或 mihomo。
- 本期 User Stories 中的支持能力有对应自动化行为测试或真实平台记录；限制与 UI/能力声明一致。
- 配置不兼容不会静默变成缺节点、缺规则或默认直连；失败恢复和最新意图得到验证。
- 退出所有权、特权完整性和产品隔离契约通过；不能完成的资源清理有可见失败结果。
- 支持矩阵按平台、架构和 TUN 模式记录；普通代理的可交付性不依赖所有实验 TUN 模式通过。
- 安装包内客户端、host、manifest 和 Helper 匹配，升级与卸载只影响新产品。

## Out of Scope

- Android、iOS，以及任何移动端架构、JNI/C bridge、系统 VPN 或分阶段移动端实施设计。
- 双内核支持、运行时内核选择、mihomo fallback、跨内核配置切换或数据迁移。
- 扩展 meow-rs 的代理协议、规则、组网、DNS 追踪、节点流量、UDP 连接明细或 Go 诊断等能力来追平 mihomo。
- 为对齐旧 wrapper 补齐全部方法、逐事件观测或资源更新事务。
- 完整复刻 mihomo 的热更新；除模式和日志级别外，本期采用明确的受控重启行为。
- 自动删去不支持内容后继续应用配置，以及一键迁移 FlClash 的整个数据库、私有 matcher cache 或运行态缓存。
- 任意路径的特权执行、通用特权文件操作或扩大 Helper 的通用管理权限。
- 全面视觉品牌重做、额外 CPU 指令集优化包、全新 REST 面板功能以及性能领先 mihomo 的承诺。
- 将 Rust host 上游化，或在本次写方案时实际创建远程 fork、修改内核、安装服务及发布软件。

## Further Notes

### 实施顺序与阶段验收

1. **建立独立产品基线。** 建立两个 fork、固定来源提交和产品标识，整理桌面支持/限制清单，移除新客户端的双内核与移动端发布范围。完成条件是后续代码和安装产物不会覆盖原产品。
2. **打通 Rust host 控制路径。** 实现 IPC envelope、握手、初始化、错误处理、终止和 direct launch，接入现有 CoreController/生命周期。完成条件是跨语言控制测试和单进程退出归属通过。
3. **完成普通代理与配置。** 接入兼容检查、配置应用、listener 启停、代理组、测速、流量、连接、日志与 provider，完成能力相关 UI 清理。完成条件是本地流量 e2e、配置失败恢复和连续操作收敛通过。
4. **完成特权与桌面 TUN。** 替换 Helper 的固定可信 host，验证捕获范围、授权降级、网络资源释放及异常恢复。完成条件是各平台有实际验收记录，未通过模式被明确限制。
5. **完成安装交付与维护入口。** 替换构建、缓存、打包和更新源，移除 Go/mihomo 桌面依赖，执行全部发布门槛。完成条件是从干净环境构建和安装的新产品可独立使用、更新及卸载。

### 维护约束

主要长期成本是 meow 公共 Interface 变化对 host 的影响、配置差异策略、原生网络资源验证和 FlClash UI 改动的挑选合入。该方案不承担双内核维护或功能追平成本。

host 专属协议和 Adapter 集中在独立 crate；对其他 meow Module 的改动要能明确说明是宿主接入必需。保持已有 meow CLI 和上游测试可构建运行，避免 fork 的客户端接入改变独立 CLI 的默认行为。

上游更新应在明确的提交范围中完成，先验证配置和 host 契约，再进行各平台构建与运行检查。版本记录同时标明客户端来源、内核上游基线、自有 fork 提交和 host 协议版本。

本方案来自本地代码调查和会话决策，尚无 Rust host 构建、吞吐量、内存或真实 TUN 运行结果；不据此估算已完成程度或承诺性能收益。

### Issue 发布状态

当前会话和仓库说明未提供 issue tracker 与 triage 标签配置。依照 to-spec 技能，需先运行 `/setup-matt-pocock-skills` 配置目标 tracker 和标签词汇，之后将本文发布为 issue 并应用 `ready-for-agent`。不根据多个 Git remote 猜测应发布到现有产品还是新客户端 fork。
