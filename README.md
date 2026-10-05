# FlClash HarmonyOS

HarmonyOS-only 原生 ArkTS/ArkUI 代理客户端，集成真实 Mihomo VPN/TUN，界面参考 FlClash，非其官方发行版。当前集成目标为 Mate 60 Pro / API 24，仅支持 ARM64；交付物是设备授权的自用开发签名包，不是商店发行版本。

支持 URL/系统文件选择器导入配置、更新/替换/回滚、规则/全局/直连、节点选择与延迟、实时流量/连接/日志，以及持久化主题和设置。用户自行提供合法有效的 Mihomo 配置；仓库不包含个人订阅。

## AI Coding 入口

先读 [AGENTS.md](AGENTS.md)，再根据任务阅读 [源码结构与架构](docs/architecture.md)。详细文档集中在 [docs/](docs/README.md)，不在项目首页重复维护。

## 项目结构

```text
.
├── AGENTS.md                     # AI 开发约束与验证要求
├── README.md                     # 项目简介和导航
├── docs/                         # 技术文档
│   ├── README.md                 # 文档索引
│   ├── architecture.md           # 源码分层、运行链路和工程边界
│   ├── project-guide.md          # 构建/签名/安装/使用/实测/归属
│   └── development-retrospective.md # 开发与测试复盘
├── harmony/                      # 完整 DevEco 工程和应用源码
│   ├── entry/src/main/ets/       # ArkTS UI、服务、存储与 VPN 扩展
│   ├── entry/src/main/cpp/       # N-API/C++ 原生桥接
│   ├── entry/src/main/resources/ # UI 资源、CA 与 geodata
│   ├── core/                    # Go/Mihomo 集成与固定 vendor 依赖
│   ├── scripts/                 # 工具链、构建与安装入口
│   └── third_party/             # 固定 OpenHarmony Go 源码归档
├── LICENSE                      # 项目许可证
└── LICENSES/                    # 补充许可证原文
```

`harmony/` 保持 DevEco 标准工程布局，不增加重复的 `src/` 包装。私有签名配置、个人输入、IDE 缓存、原生库与 HAP 等生成内容不属于可发布源码。

## 文档与构建

- [项目指南](docs/project-guide.md)：SDK、开发签名、构建安装、日常操作与历史实机验证。
- [源码结构与架构](docs/architecture.md)：修改入口、控制/数据面、配置和生成目录归属。
- [开发与实机测试复盘](docs/development-retrospective.md)：已确认问题、误判、验收清单及安全清理。

先按[构建准备](docs/project-guide.md#build-on-macos-with-deveco-studio)配置 DevEco/SDK 和本地开发签名，再从仓库根目录执行：

```sh
./harmony/scripts/build-core.sh
./harmony/scripts/build-hap.sh
./harmony/scripts/install-hap.sh
```

签名包生成于 `harmony/entry/build/default/outputs/default/entry-default-signed.hap`。多设备安装使用 `HDC_TARGET` 指定获授权设备；首次使用需用户批准系统 VPN 授权。开发证书可能到期，切换包或卸载前先正常停止 VPN。

## 安全、许可与验证边界

不要提交或分享订阅 URL、代理密码、控制器 token 或签名材料；不能仅凭忽略规则认定源码 ZIP 安全。历史 smoke 不等于长期稳定或每个后续版本自动通过，实际结果和未验证边界见项目指南与复盘。

项目集成 GPL-3.0 Mihomo；CA、geodata 与其他依赖有各自的许可、来源和分发限制。保留 [LICENSE](LICENSE)、[LICENSES/](LICENSES/) 及上游通知，分享源码/二进制前阅读[证书信任说明](docs/project-guide.md#certificate-trust)和[资源归属](docs/project-guide.md#bundled-geodata-and-attribution)。
