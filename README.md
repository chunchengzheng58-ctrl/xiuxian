# 疯狂修仙，中

一款以像素仙村为起点的修仙 RPG。创建自己的修士，闯秘境、练招式、养装备，也可以组队探索、与好友论剑，或者参加公开匹配冲击榜单。项目由 Godot 客户端和独立游戏服务端组成。

## 下载与试玩

| 入口 | 内容 | 启动方式 |
| --- | --- | --- |
| [Windows x64 试玩包](https://github.com/chunchengzheng58-ctrl/xiuxian/releases/download/commercial-preview-20261107/commercial-windows-preview.zip) | 11 月 7 日 PVP 与 Boss 更新版 | 完整解压后双击 `Play.vbs`。本地服务随游戏启动 |
| [Web 导出包](https://github.com/chunchengzheng58-ctrl/xiuxian/releases/download/commercial-preview-20261107/commercial-web-preview.zip) | 同期网页试玩构建 | 将解压后的静态文件通过 HTTP 服务打开。联网玩法需要可访问的游戏服务端 |
| [浏览器试玩](https://chunchengzheng58-ctrl.github.io/xiuxian/) | GitHub Pages 上的早期演示 | 直接打开，等待游戏资源加载 |

Windows 版首次启动可注册本地试玩账号。账号和进度随包保存在 `data-save/`，更换目录或版本前可先备份该目录。多人玩法需要两位玩家连接同一个游戏服务端，本机可打开两个游戏窗口，用两个账号体验。

[查看 PVP 与 Boss 更新版发布说明](https://github.com/chunchengzheng58-ctrl/xiuxian/releases/tag/commercial-preview-20261107)

## 你可以怎么玩

- **闯秘境，打 Boss。** 观察蓄力和攻击预警，用走位、闪避或护盾应对。更新版区分了 Boss 02、03、04 的战斗动作与造型。
- **论剑与组队。** 和好友发起切磋，或进入公开匹配争取积分、查看排行榜。也可以组队进入副本挑战。
- **养成与交易。** 用战斗奖励祈愿、强化和铭刻装备，搭配不同流派与套装，也可以在市场上架和购买装备。
- **社交与家族。** 建立名片、添加好友、发送私信。原型还保留家族角色、个人计划和渡劫主题玩法。健康相关演示由用户或家属确认，游戏进度独立于现实健康状况。

第一次玩可以先创建角色，从仙村进入秘境，熟悉攻击、闪避和护盾。拿到首战奖励后，试一次祈愿或装备强化，再到论剑入口体验匹配。

![像素仙村早期实机画面](output/04-pixel-village.png)

## 第一次进入仙村

1. **创建角色。** 首次启动 Windows 版时注册试玩账号，选好形象，然后进入「我的角色 · 本人」。正式秘境和论剑可以直接从本人角色开始。
2. **打一场秘境。** 先观察 Boss 的蓄力动作，避开预警区域，再抓住收招空档近身反击。优先记住踏云步和护体，遇到连续攻击时留好灵力和体力。
3. **把奖励投入下一战。** 通关后回仙村，在聚宝阁查看祈愿和行囊。穿上获得的装备，再到锻造台比较强化前后的属性。
4. **找一位同道。** 两个账号连接同一游戏服务后，可以从同道录发送好友申请和约战，也可以跳过加好友，直接进入公开匹配。

## 战斗操作

| 按键 | 动作 |
| --- | --- |
| WASD / 方向键 | 移动与调整出招方向 |
| J | 普通攻击 |
| 1 | 听风剑诀 |
| 2 / 空格 | 踏云步，用于闪避和拉开距离 |
| 3 / K | 云罡护体 |
| 4 / R | 饕餮归元。论剑统一开放，部分练习入口按进度解锁 |

网页触屏模式提供虚拟摇杆和技能按钮。练习、好友切磋、公开匹配和正式秘境各有自己的结算入口。

## PVP 怎么玩

| 模式 | 如何开始 | 战果 |
| --- | --- | --- |
| 公开匹配 | 在「论剑台 / 对战」设置公开昵称并开始匹配。排队中可取消，配对后进入擂台 | 记录胜负、积分变化及公开排行榜 |
| 好友切磋 | 在论剑台切换「好友切磋」，或从同道录发出约战。对方接受后开始倒计时 | 记录近期战绩，匹配积分保持原值 |

两种论剑均使用统一基础属性，装备与主线养成的属性加成用于 PVE。短暂断线时，双方可以等待恢复并继续原局。

## Boss 与装备

- **三位首领。** 朽梁是残梁机关，涩节是低矮转轴机关，窃荣是木心鹿。三个 Boss 的造型和战斗动作各自独立。入场后先看预警位置和首领起手，再决定贴身输出或拉开。
- **祈愿与流派。** 在聚宝阁选择流派，查看概率和累计传说保障，再进行单抽或十连。祈愿所得可在行囊查看。
- **锻造与套装。** 强化最高可达 +10，铭刻可更换流派。同流派装备达到 2 件或 4 件时可获得对应的 PVE 套装加成。
- **万宝集交易。** 卖家可将未穿戴的装备定价上架，买家可按部位找装备。成交后，装备的原强化等级和流派一并交付。「我的交易」可查看成交或撤单。

## 版本路线

- **PVP 与 Boss 更新版**是首页推荐试玩包，包含三关正式秘境、公开匹配、好友切磋、社交和装备交易。
- **五域归衡主线扩展**从苍梧林的木域线索开始，经历五域并收集归衡印，包含二十个正式秘境、九章剧情和最高 30 级的冒险成长。已发布独立 [Windows 主线试玩包](https://github.com/chunchengzheng58-ctrl/xiuxian/releases/tag/five-realms-preview-20261107)。
- **GitHub Pages** 提供较早的浏览器演示。各试玩包使用各自的默认数据目录，换包后可用新账号体验；需要迁移进度时先参照存档说明备份。

## PTDS 穿戴数据

桌面源码版可预览从 Mac 上的 PTDS 导出的 Oura 单日步数和睡眠时长。从「每日修行 → PTDS 穿戴摘要」确认本人今日记录，可领取现有每日修行奖励，与其他每日任务共用一次额度。安装、授权流程与导出命令见 [PTDS 接入指南](docs/PTDS.md)。

## 源码与开发

`main` 保留基础 Godot 工程。要查看带游戏服务端、PVP 及主线扩展的开发源码，请切换到 [`codex/five-realms-preview`](https://github.com/chunchengzheng58-ctrl/xiuxian/tree/codex/five-realms-preview)。该分支也包含「五域归衡」主线扩展。要体验上方发布的 PVP 与 Boss 试玩版，请使用 Release 附件，构建信息记录在附件的 `manifest.json` 中。

```bash
git clone --branch codex/five-realms-preview https://github.com/chunchengzheng58-ctrl/xiuxian.git
cd xiuxian
npm --prefix server ci
npm --prefix server run dev
```

开发版使用 Godot 4.7.2 和 Node.js 24.13 或以上的 24.x。服务启动后，用 Godot 打开根目录的 `project.godot`，按 F5 运行。服务端配置见 `server/.env.example`，编译与自动测试可运行 `npm --prefix server run check`。

| 目录 | 用途 |
| --- | --- |
| `scenes/`、`scripts/` | Godot 场景、仙村界面、战斗和客户端逻辑 |
| `assets/`、`data/` | 像素美术、动作、音效和游戏配置 |
| `server/` | 账号、存档、联机对局与游戏结算 |
| `tests/`、`tools/` | 回归测试、构建及试玩验证 |

- [试玩指南](https://github.com/chunchengzheng58-ctrl/xiuxian/blob/codex/five-realms-preview/docs/PLAYTEST_GUIDE.md)
- [Windows 打包与存档说明](https://github.com/chunchengzheng58-ctrl/xiuxian/blob/codex/five-realms-preview/docs/WINDOWS_BUILD.md)
- [五域归衡主线试玩](https://github.com/chunchengzheng58-ctrl/xiuxian/blob/codex/five-realms-preview/docs/CAMPAIGN_PLAYTEST.md)

## 常见问题

| 遇到的情况 | 可以先检查 |
| --- | --- |
| Windows 解压后无法登录 | 从完整解压的目录运行 `Play.vbs`，它会启动本地游戏服务 |
| 两个账号一直匹配不到 | 检查两个窗口是否连接同一个服务，是否分别登录不同账号，并且都进入公开匹配 |
| 更新后找不到原角色 | 核对启动目录及所连接的服务。Windows 试玩包默认将账号数据保存在各自的 `data-save/` |
| 浏览器版能打开，联网功能却不可用 | 检查客户端连接的游戏服务是否可访问。Web 附件只包含静态客户端 |
| 祈愿超时，余额已变动 | 重连后用界面的「继续上次单抽/十连」确认原请求，再到行囊核对结果 |

提交问题时，请附上试玩版本、运行平台、复现步骤和截图。贡献代码时请从对应开发分支创建功能分支，提交场景或脚本时一并提交关联的 `.uid` 和导入配置。
