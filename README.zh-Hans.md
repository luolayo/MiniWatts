# MiniWatts

[English](README.md) · **简体中文**

[![Build](https://github.com/ResistanceTo/MiniWatts/actions/workflows/build.yml/badge.svg)](https://github.com/ResistanceTo/MiniWatts/actions/workflows/build.yml)

一个用 Apple 私有 API 做的 iPhone 电池与充电信息 app。它读取手机自己的电源管理传感器——也就是 iOS 用来控制充电的那一套——显示充电器正在输出多少、其中有多少真正进到电芯、两者之间的功率差额，以及关键部件与分区温度。现在也显示设备的实时上传、下载速率。

> 下方截图为旧版布局，新版导航为“总览 / 记录 / 设置”。电池和供电路径保留在总览，温度与充电器详情可继续展开查看。

| 功率 | 温度 | 充电器 | 历史 |
|:-:|:-:|:-:|:-:|
| <img src="docs/screenshots/power.jpg" width="200" alt="功率"> | <img src="docs/screenshots/thermal.jpg" width="200" alt="温度"> | <img src="docs/screenshots/adapter.jpg" width="200" alt="充电器"> | <img src="docs/screenshots/history.jpg" width="200" alt="历史"> |

> **只能自签安装。** 用了私有 API，所以永远上不了 App Store，需要你自己签名安装。测量数据保留在本机。网速监测读取本地接口计数器；流量消耗器只在你手动开始后访问填写的下载链接。

## 安装

从 [Releases](https://github.com/ResistanceTo/MiniWatts/releases) 下载最新的
`MiniWatts-unsigned.ipa`，用你自己的 Apple ID 签名安装——[Sideloadly](https://sideloadly.io)、
[AltStore](https://altstore.io)、[SideStore](https://sidestore.io) 和 Xcode 都可以。
免费 Apple ID 可用，但应用 7 天后过期，需要重新签名。

运行要求：iPhone，iOS 17 或更高版本。

也可以在 SideStore 或 AltStore（包括 LiveContainer 自带的 SideStore）里添加这个源，从源里安装，之后新版本会作为更新出现：

```
https://github.com/ResistanceTo/MiniWatts/releases/latest/download/apps.json
```

LiveContainer 无法运行 App 扩展，所以装在 LiveContainer 里的 MiniWatts 没有小组件，也没有实时活动。

MiniWatts 带有主屏幕与锁定屏幕小组件，以及显示功率、温度和网速的灵动岛 / 锁屏实时活动。签名时小组件扩展会多占用一个 App ID——免费 Apple ID 每周只能注册 10 个；如果签名工具提示移除扩展，移除后就没有小组件了。

## 它做不到的事

传感器叫什么、怎么换算、甚至有没有这个传感器，都因 iPhone 机型而异，而且没有任何官方文档。这个版本是在 iPhone Air 上开发和验证的，换一个机型，某项读数可能不存在，也可能名字和实际含义对不上。不可能出现的数值——比如真有人看到充电芯片显示 −9199 °C——会被隐藏而不是显示出来，但一个看着合理、实际却是错的数值拦不住。看到反常的数字，请带上机型标识反馈。

只能显示 iOS 真正交给沙盒应用的数据。电池健康度和循环次数被从注册表里过滤掉了；配件电量（Watch、AirPods）返回的是空列表；无线充电不暴露输入电流，所以用 MagSafe 时只能看到进入电芯的部分；放电功率没有对应传感器，只能按电量百分比估算。充电暂停只能靠行为推断，推断出来的应用会标注 `inferred`。

“充电器详情”增加充电协议信息：只有系统上报有效档位并明确选中其中一档时，才显示“USB-PD（推断）”。仅有档位列表、电压、功率或充电器名称时，当前协议仍显示“未识别”。现有数据无法可靠识别 PD 版本、PPS 使用情况、QC，或区分 Qi、Qi2、MagSafe。

小组件何时刷新由 iOS 决定。应用运行并检测到充电时会自动显示实时活动，约每秒提交一次新读数；灵动岛实际显示频率由 iOS 决定。应用挂起且没有获准的后台任务时，读数会标为已暂停，并保留最后一次读数和时间。

无需打开应用也要在插电时显示，可在系统“快捷指令”中创建“充电器已连接”自动化，运行 MiniWatts 的“显示充电实时活动”；断开时创建“充电器已断开”自动化，运行“结束充电实时活动”。该动作会在后台启动应用进程并创建实时活动。后台持续更新需要手动开启并获准“后台监测”；单靠实时活动或快捷指令动作不能使应用持续运行。

网速是设备 Wi-Fi、蜂窝和以太网接口的收发流量，包含其他 App 及局域网通信，不能用于判断宽带最高速度或某个 App 的独立流量。排除 VPN 隧道接口以避免重复计数。切换网络、恢复前台及计数器重置后会重新采样，无法读取时显示“—”。1 MB/s = 每秒 1,000,000 字节。不同 iOS 版本的可读范围和 VPN 场景仍需真机验证。

## 流量消耗器

从总览的“实时网速”卡片进入。内置平台分组已移除。填写配置名称、HTTPS 下载直链、流量目标、单位、并发数和跳转规则后，点击“保存设置”。下次打开可从“已保存配置”选择，支持修改、覆盖保存、新建及删除。配置只保存在本机 App 的私有偏好存储中。

目标单位支持 MB / GB（十进制，1 GB = 1000 MB），允许小数；已移除 10 GB 上限，400 GB 等大目标可一次设置。默认时间上限为“不限时”，到达总流量目标才停止，也可选择时间上限。仍支持 1–64 路并发，默认 4 路。“一键最大速度”会忽略手动线程设置，直接使用 64 路并发，小文件完成后立即补位。实际吞吐仍取决于下载源、文件大小、网络和系统限制，不能保证任何链接都跑满网速。总量按 64 位整数精确计算，各请求共享目标，避免每路重复领取全部目标。

已保存配置每隔约 1 分钟及停止时保存进度。下次选择同一配置可点击“继续剩余”恢复剩余目标，也可点击“开始下载”从零开始。重开 App 不会自动发起下载。强制终止前尚未保存的少量进度可能丢失，统计也不等于运营商账单。

iOS 26 及以上可申请后台继续下载。请等到显示“已获准后台运行”后再切换 App；未获准会显示原因并仅前台运行。后台下载只显示系统任务的一张实时活动卡片。系统可能提前取消任务，应用不会自动绕过系统限制或偷偷重启。数据流接收后丢弃，不保存大文件。

下载内容只经内存接收、计数后丢弃，不创建下载文件、续传数据文件或响应磁盘缓存。设置、少量进度记录、充电历史和系统自身仍会有少量存储写入，不能保证设备完全零写入；相同设置不会重复写入。

每个请求最多约 32 MiB；服务器忽略 Range 时也会主动结束该请求并继续剩余目标。小文件成功下载后立即补充该并发槽位的下一个请求，不再固定等待 1 秒。临时断线、超时及 HTTP 408/429/500/502/503/504 会按 1 / 2 / 4 / 8 / 16 / 30 秒间隔自动重试，每路最多连续重试 6 次，成功完成分段后重置次数。已接收流量保留，其他健康线程继续。遵守不超过 5 分钟的 Retry-After，超过则显示 HTTP 状态并停止；无权限、证书、跳转限制和永久 HTTP 错误不自动重试。页面显示重试次数、重连状态和错误码，不显示链接中的私密参数。手动停止、达到目标、时限或后台执行结束均会取消等待中的重试。

## 独立后台实时监测

在灵动岛设置中选择 1 / 4 / 8 小时并开启“后台监测”，获准后即可切换其他 App；不需要下载。这个功能只在充电时可开启，拔电后结束。

后台监测由系统卡片显示功率和电量；开始下载时先结束监测任务，避免出现两张任务卡片。系统可撤销执行时间、决定展示位置和刷新频率；划掉进程也会终止工作。需真机验证，不能承诺永不中断或严格每秒显示。

若提示签名标识不匹配，请在签名时保留 Bundle ID，或同步更新 `BGTaskSchedulerPermittedIdentifiers` 中的 `traffic.*` 和 `monitoring.*` 前缀。

默认禁止跨域跳转：主机和端口必须与初始链接一致，子域名也视为不同来源。可在页面明确选择“允许 HTTPS 跨域跳转”，这时展示实际请求域名；仍禁止跳转到 HTTP，并限制重定向次数。不会打开网页、加载子资源或转发 Cookie、登录凭据及 Referer。

下载使用当前系统网络，不强制选择蜂窝网络。**保存配置或域名不保证计入定向流量**；部分套餐仅限官方 App 内的指定内容，请核对自己的[运营商套餐说明](https://wap.gs.10086.cn/gsecwap/DyKs.html)。使用蜂窝流量前请关闭 Wi-Fi。网页、分享页和播放列表需要先换成可直接下载的资源链接。

## 构建

Xcode 26 或更高版本，iOS 17 部署目标，无第三方依赖。

```bash
./scripts/check-network.sh                         # 网速与实时活动数据检查（macOS Swift）
./scripts/check-charging-protocol.sh               # 充电协议判定与信息缺失场景
./scripts/check-traffic-consumer.sh                # 本地模拟响应检查，不消耗外部流量
./scripts/check-background-lifecycle.sh            # 模拟独立监测/下载的后台生命周期
./scripts/check-traffic-settings.sh                # 保存、恢复、续跑、400 GB 与数值边界
./scripts/build-ipa.sh                             # 不签名，Releases 发布的就是这个
TEAM_ID=ABCDE12345 ./scripts/build-ipa.sh signed   # 签名，装自己的设备
```

[`CLAUDE.md`](CLAUDE.md) 是这个项目的工程笔记：沙盒具体封了哪些 API、结论是怎么验证出来的、每个传感器最后查明是什么，以及这个项目已经踩过的 Swift 6 隔离陷阱。

## 许可

Apache 2.0，见 [LICENSE](LICENSE)。读取 PMU 的方法衍生自
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor)（MIT），
`BatteryCenterBridge` 有两处细节参考自 [Batsie](https://github.com/leptos-null/Batsie)。
两者都记录在 [NOTICE](NOTICE) 中，上游的 MIT 声明也逐字保留在那里。

私有 API 可能在任何一次 iOS 更新中变化或消失。
