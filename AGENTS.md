# AI Coding 入口

本文件适用于整个仓库。开始修改前先读 [README](README.md) 和 [源码结构与架构](docs/architecture.md)；构建、实机测试分别参考 [项目指南](docs/project-guide.md) 与 [开发复盘](docs/development-retrospective.md)。不要把历史实测结果当成本次改动的验证。

## 项目边界

- HarmonyOS-only、ARM64、原生 ArkTS/ArkUI，使用真实 Mihomo VPN/TUN。集成目标为 Mate 60 Pro / API 24；编译 SDK 26，最低兼容 API 22。
- 不引入 Flutter、模拟代理数据、WebDAV 或额外配置覆盖功能。保留用户规则、provider、DNS 上游和代理组选择；平台必要的 TUN、内部 DNS 与 loopback 控制器约束见项目指南。
- 自用开发签名包不是商店发行包。证书与 geodata 许可需要单独遵守，见项目指南的信任链和归属说明。

## 目录与修改范围

| 路径 | 职责 |
| --- | --- |
| `harmony/entry/src/main/ets/` | ArkTS UI、应用服务、存储、VPN 扩展 |
| `harmony/entry/src/main/cpp/` | N-API/C++ 桥接和原生模块类型声明 |
| `harmony/core/` | Go/Mihomo 平台集成；`vendor/` 为固定版本依赖 |
| `harmony/entry/src/main/resources/` | UI 资源、CA 与 geodata |
| `harmony/scripts/` | 工具链准备、核心构建、HAP 构建与安装 |
| `harmony/third_party/` | 固定版本的 OpenHarmony Go 源码归档 |
| `docs/` | 项目指南、架构、复盘及后续技术文档 |

`harmony/` 是完整 DevEco 工程根目录，不再套一层 `src/`，不为整理目录移动其内部模块。`LICENSE`、`LICENSES/` 保留标准根目录位置。新技术文档放 `docs/`，README 只维护简介、目录和导航。

## 实现约束

- 优先改项目自身集成层；确需改 `vendor/` 或工具链时，范围最小、保留上游通知，并更新相关校验值、归属和构建说明。
- Go 核心必须按 OpenHarmony ARM64/cgo 构建，并保留 `with_gvisor`。普通 Linux/Android 编译不能替代设备兼容验证。
- 使用公开 HarmonyOS API。TUN descriptor 由系统创建，原生层拥有其复制副本；出站绑定可用的非 VPN 物理网络，不引入自行修改系统路由或非公开 socket API。
- 控制器仅监听带鉴权的 loopback。按 API 24 核对运行时接口，不能仅因 SDK 26 编译成功就采用较新设备 API。
- VPN 停止确认必须在扩展上下文存活时完成，并匹配本次 request ID；不要靠 `onDestroy` 返回后的异步写入或放大超时掩盖问题。
- 配置更新保持验证、原子替换、失败回滚和运行状态恢复。文件替换重新通过系统 picker 获取授权 URI；取消操作不得报成功。
- 稳定 `ForEach` key 的回调需从最新 snapshot 解析可变字段。网络 `Map` 使用 `.get/.has/.set`，不要按普通对象下标访问。
- 保持系统/浅色/深色主题一致。不要静默关闭 HTTPS 证书验证；用户配置自身要求的跳过验证，应说明风险。

## 工作与验证

1. 先核对相关实现、调用方与既有约定，明确变更和验收场景；遇到用户的未预期改动应保留，不覆盖。
2. 独立任务可并行，但共享接口需先约定；构建和设备操作由一个集成负责人执行。不要在构建中途改相关源码，或让多个执行方同时操作手机。
3. 所有构建命令从仓库根目录执行：Go/核心依赖改动先运行 `./harmony/scripts/build-core.sh`，再运行 `./harmony/scripts/build-hap.sh`；仅 ArkTS/C++/资源改动运行后者。首次签名准备见项目指南。
4. 仅在设备已授权时安装：`HDC_TARGET=<authorized-connect-key> ./harmony/scripts/install-hap.sh`。先正常停止已有 VPN，再更换运行包；锁屏/弹窗遮挡时停止 UI 输入，不索取解锁密码。
5. 行为改动验证实际路径：UI 看设备真实画面；VPN 用新外部请求；配置失败核对旧内容和时间戳；停止核对核心与 OS 接口。不能用编译成功、mock 回声或源码字符串测试代替行为证明。
6. Bug 尽量保留失败前/修复后的消费者可见回归；确定性测试覆盖边界与状态转换，不测试文案、转发 wiring 或实现细节。实机检查使用复盘中的验收表。
7. 纯文档整理验证相对链接、锚点、示例语法和路径即可，不应为此重装应用或改变手机网络。涉及工程路径迁移才需要构建验证。
8. 完成后更新相关文档，移除临时诊断、fixture 服务和自己的端口转发；清理测试下载及文件，恢复原网络/屏幕设置。报告实际执行的检查及未验证范围，不把一次 smoke 推断为长期稳定。

## 私密数据与提交

- 不读取或展示用户私密数据，除非当前任务确实需要且用户已授权；不打印订阅 URL、代理密码、Bearer token、签名密钥/密码。
- `harmony/private/`、`harmony/build-profile.json5`、签名文件、生成的库/HAP、IDE/构建缓存不入库。首次只从签名模板生成本地配置，不覆盖现有签名配置。
- fixture 使用不含凭据的最小配置；截图检查输入框与系统覆盖窗口，裁剪后确认尺寸和遮盖范围。忽略规则不等于 ZIP/源码目录分享自动安全。
- 只在用户要求时提交/推送；检查实际暂存内容，不强推、不改写已有提交，不提交临时诊断或个人配置。
