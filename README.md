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

## 源码与开发

`main` 保留基础 Godot 工程。要查看带游戏服务端、PVP 及主线扩展的开发源码，请切换到 [`codex/five-realms-preview`](https://github.com/chunchengzheng58-ctrl/xiuxian/tree/codex/five-realms-preview)。该分支也包含「五域归衡」主线扩展。要体验上方发布的 PVP 与 Boss 试玩版，请使用 Release 附件，构建信息记录在附件的 `manifest.json` 中。

```bash
git clone --branch codex/five-realms-preview https://github.com/chunchengzheng58-ctrl/xiuxian.git
cd xiuxian
npm --prefix server ci
npm --prefix server run dev
```

开发版使用 Godot 4.7.2 和 Node.js 24。服务启动后，用 Godot 打开根目录的 `project.godot`，按 F5 运行。服务端配置见 `server/.env.example`，编译与自动测试可运行 `npm --prefix server run check`。

| 目录 | 用途 |
| --- | --- |
| `scenes/`、`scripts/` | Godot 场景、仙村界面、战斗和客户端逻辑 |
| `assets/`、`data/` | 像素美术、动作、音效和游戏配置 |
| `server/` | 账号、存档、联机对局与游戏结算 |
| `tests/`、`tools/` | 回归测试、构建及试玩验证 |

- [试玩指南](https://github.com/chunchengzheng58-ctrl/xiuxian/blob/codex/five-realms-preview/docs/PLAYTEST_GUIDE.md)
- [Windows 打包与存档说明](https://github.com/chunchengzheng58-ctrl/xiuxian/blob/codex/five-realms-preview/docs/WINDOWS_BUILD.md)
- [五域归衡主线试玩](https://github.com/chunchengzheng58-ctrl/xiuxian/blob/codex/five-realms-preview/docs/CAMPAIGN_PLAYTEST.md)

提交问题时，请附上试玩版本、运行平台、复现步骤和截图。贡献代码时请从对应开发分支创建功能分支，提交场景或脚本时一并提交关联的 `.uid` 和导入配置。
