# 源码结构与架构

## 1. 仓库分层

```text
.
├── AGENTS.md                         # AI Coding 入口与全仓约束
├── README.md                         # 项目简介和导航
├── docs/                             # 指南、架构、复盘
├── LICENSE                           # 项目许可证
├── LICENSES/                         # 补充许可证原文
└── harmony/                          # 完整 DevEco 工程根目录
    ├── entry/                        # HarmonyOS 应用模块
    │   └── src/main/
    │       ├── module.json5          # UI Ability、VPN 扩展与权限声明
    │       ├── ets/                  # 项目自有 ArkTS 源码
    │       │   ├── entryability/     # UI Ability 入口
    │       │   ├── pages/            # ArkUI 页面和交互
    │       │   ├── services/         # 应用操作、配置事务、控制器与遥测
    │       │   ├── storage/          # 私有配置、原子写入与持久化
    │       │   ├── model/            # snapshot、配置和连接等数据类型
    │       │   └── vpn/              # VPN 扩展生命周期及网络观察
    │       ├── cpp/                  # N-API/C++ 桥接与 types/ 类型声明
    │       └── resources/            # 页面资源、CA、geodata
    ├── core/                         # Go 模块
    │   ├── main.go                   # 项目自有 Mihomo/TUN/物理网络集成
    │   ├── go.mod / go.sum           # Go 依赖与校验
    │   └── vendor/                   # 固定版本上游源码和通知
    ├── scripts/                      # 工具链准备、构建与安装
    ├── third_party/                  # OpenHarmony Go 源码归档
    ├── build-profile.template.json5  # 可入库的签名/构建模板
    ├── hvigorfile.ts                 # DevEco/Hvigor 工程入口
    └── oh-package*.json5             # 工程依赖元数据
```

`harmony/` 已是清晰的应用源码与工程边界。保持 DevEco 标准的 `entry/src/main/`，Go 与 C++ 使用各自适配的目录；不增加 `src/harmony/` 包装，也不把 Go `vendor/` 混入 ArkTS 源码。

## 2. 主要实现入口

| 文件 | 责任 |
| --- | --- |
| [EntryAbility.ets](../harmony/entry/src/main/ets/entryability/EntryAbility.ets) | UI Ability 入口与设备配色状态 |
| [Index.ets](../harmony/entry/src/main/ets/pages/Index.ets) | 概览、配置、代理、连接、日志与设置；最新 snapshot 的行字段解析 |
| [AppService.ets](../harmony/entry/src/main/ets/services/AppService.ets) | 串行应用操作、导入/更新/回滚、模式与节点选择、鉴权控制器、遥测和运行状态协调 |
| [PrivateStore.ets](../harmony/entry/src/main/ets/storage/PrivateStore.ets) | 私有 YAML、元数据、控制器凭据、主题/模式/每配置组选择的持久化 |
| [Models.ets](../harmony/entry/src/main/ets/model/Models.ets) | UI snapshot、profile、group、node、connection 等共享模型 |
| [FlClashVpnAbility.ets](../harmony/entry/src/main/ets/vpn/FlClashVpnAbility.ets) | 创建/销毁系统 VPN、heartbeat、停止确认、网络观察和资源准备 |
| [bridge.cpp](../harmony/entry/src/main/cpp/bridge.cpp) | ArkTS↔Go 的 N-API 接口、异步 inspect/start、错误与结果所有权 |
| [main.go](../harmony/core/main.go) | Mihomo 配置/TUN 生命周期、descriptor 复制、物理网络出站绑定和 DNS 传输刷新 |

目前 [module.json5](../harmony/entry/src/main/module.json5) 未为 VPN 扩展配置独立进程名。逻辑上的 UI/服务/扩展分层不代表独立 OS 进程，诊断时不能只按名称推断 VPN 进程死亡。

## 3. 运行与状态链路

- **数据面：** 系统 VPN 创建 TUN → VPN 扩展把 descriptor 交给原生桥接 → Go/Mihomo gVisor 处理 DNS、规则和流量 → 出站 socket 绑定非 VPN 的可用物理网络。
- **控制面：** ArkUI 页面 → `AppService` → 带鉴权的 `127.0.0.1:9097` 控制器，执行模式、组选择、延迟和连接操作；traffic/log WebSocket 提供实时遥测。
- **生命周期：** `AppService` 发起 VPN 扩展请求；扩展记录运行 phase、heartbeat 和关联 request ID。正常停止在仍存活的扩展请求中等待核心与 OS 接口清理，确认后再终止扩展。
- **持久化：** 私有 profile YAML 与元数据由存储层原子写入。运行状态文件用于协调扩展，不应以旧 heartbeat 或仅 UI 按钮状态替代实际核心/数据面验证。
- **UI 更新：** 服务发布 snapshot；稳定列表 key 不变时，行内可变字段也必须解析最新对象。

不得把“监听器可达”“已鉴权 API 成功”“系统 VPN 存在”“外部请求经过代理”混为同一条证据。完整诊断和验证方法见 [开发复盘](development-retrospective.md)。

## 4. 构建与配置归属

所有构建命令从仓库根目录执行，详细环境准备见 [项目指南](project-guide.md#build-on-macos-with-deveco-studio)。

- [build-core.sh](../harmony/scripts/build-core.sh) 以脚本位置确定 `harmony/`，准备固定 Go 工具链并编译 `core/`，产生忽略的 `libs/arm64-v8a/libmihomo.so` 与头文件。
- [build-hap.sh](../harmony/scripts/build-hap.sh) 同样定位 `harmony/`，同步模块依赖并运行 Hvigor，编译 ArkTS/C++、打包原生库/资源和开发签名。
- [install-hap.sh](../harmony/scripts/install-hap.sh) 安装约定位置的签名 HAP，并检查 HDC 的实际成功消息。
- 工程内 `entry/build-profile.json5` 属于可发布模块配置；`harmony/build-profile.json5` 是忽略的本地签名配置。不能将两者统一忽略或覆盖。
- 用户 profile 和运行状态位于手机应用私有存储，不是仓库资源。仓库 `harmony/private/` 仅用于被忽略的本地授权输入/测试材料，不可打入 HAP 或分享的源码包。

## 5. 固定输入与生成目录

| 类别 | 路径 / 处理 |
| --- | --- |
| 固定上游源码 | `harmony/core/vendor/`、`harmony/third_party/ohos-go-1.24.13-src.tar.gz`；保留来源、校验和通知 |
| 固定资源 | `harmony/entry/src/main/resources/rawfile/`；CA/geodata 的校验、信任与许可见项目指南 |
| 本地签名 | `harmony/build-profile.json5` 和个人签名材料；忽略，不覆盖、不公开 |
| 生成内容 | `harmony/libs/` 中的原生库/头文件，模块 `build/`、`.cxx/`、`.hvigor/`、`oh_modules/` 与 IDE 缓存；不作为源码编辑或提交 |
| 自用签名包 | `harmony/entry/build/default/outputs/default/entry-default-signed.hap`；忽略，仅面向获授权设备，开发证书可能到期 |

本次结构整理仅迁移项目文档、增加 AI 入口和架构说明，不移动源码、工程配置、脚本或私有材料。构建路径和生成产物约定保持不变。
