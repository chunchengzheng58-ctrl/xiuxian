# Windows 独立试玩包

构建脚本为 `tools/pack-windows.mjs`，使用官方 Godot 4.7.2 Windows x64 release 模板，随包携带 Node 24 与服务端生产依赖。它不会把开发引擎改名作为发行程序。

## 模板与来源

已核实 [Godot 官方 4.7.2 发布页](https://github.com/godotengine/godot-builds/releases/tag/4.7.2-stable) 与 [官方下载入口](https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates)。模板准备命令：

```powershell
node tools/pack-windows.mjs --templates-only
```

选择性提取官方 ZIP 的 Windows release 程序、console wrapper 与 `version.txt`，验证条目长度和 CRC32，记录各文件 SHA-256。此方法没有下载整个 1.19 GB TPZ，因此不声明已验证完整 TPZ 的 SHA-256。过程文件、模板和独立 Godot `APPDATA` 全部在项目的 `work/windows-build/`。许可文本从对应 Godot 与 Node 官方源码版本取得并随包保留。

## 构建

先完成服务端构建，再从项目根执行：

```powershell
npm.cmd --prefix server run build
node tools/pack-windows.mjs
```

`--client-only` 仅导出客户端；`--runtime-only` 在已经导出且运行源码指纹未变时补齐服务器和启动器。`XIUXIAN_WINDOWS_OUTPUT` 可指定输出目录，默认项目父级的 `outputs/commercial-preview/windows/`。`GODOT4_CONSOLE` 可指定编辑器 CLI，`GODOT_WINDOWS_RELEASE` 可指定已验证的匹配模板。

五域主线版使用独立目录，保留已打开的三关 r2：

```powershell
$env:XIUXIAN_WINDOWS_OUTPUT = 'D:\Projects\ChatGPT\涅槃\outputs\campaign-preview\windows'
node tools/pack-windows.mjs
```

该版包含二十个正式秘境、九章主线与冒险等级。新包不会自动连接旧包的数据，玩法与迁移边界见 `CAMPAIGN_PLAYTEST.md`。

导出使用独立最小源码副本，不改共享的 Web 导出配置，也不复制 `.git`、真实存档、`.env` 或工作缓存。包内 `manifest.json` 保存源码指纹、模板来源及各文件 SHA-256。

## 运行和数据

完整解压到 D 盘可写目录，双击 `Play.vbs`。启动器使用包内 Node；游戏窗口可见，后台服务隐藏且只监听随机回环端口，不使用或重启 8080 旧服务。启动器通过与包路径及数据目录对应的命名管道核对服务身份；同一包可打开多个窗口，共用一个服务。全部游戏窗口关闭后服务自动退出。

数据默认在包内 `data-save/`，其中 `server/var/` 保存服务端账号数据库，`appdata/` 保存客户端缓存，`logs/` 保存日志。升级时保留数据目录；备份/恢复参考 `DATABASE_RECOVERY.md`。本人 PVE、抽卡、装备与公开匹配无需健康档案；微信和健康识别等外部集成仍需另行配置服务。

本包默认创建独立账号库，不连接源码 8080 的旧库。旧用户名在独立空库无法登录不表示旧数据丢失；可先注册测试账号。需要保留原进度时，用随包 Node 将原库生成一致备份，再恢复至全新路径，核对后才切换。不要自动指向仍在运行的原库，例如：

```powershell
.\runtime\node.exe .\server\dist\tools\backup.js 'D:\旧项目\server\var\game.sqlite' 'D:\游戏备份\source-snapshot.sqlite'
.\runtime\node.exe .\server\dist\tools\restore.js 'D:\游戏备份\source-snapshot.sqlite' 'D:\修仙数据\恢复副本\server\var\game.sqlite'
$env:XIUXIAN_DESKTOP_DATA = 'D:\修仙数据\恢复副本'
Start-Process .\Play.vbs
```

`XIUXIAN_DESKTOP_DATA` 仅指定此启动环境的持久位置；不会修改系统环境变量或迁移文件。默认随包数据应连同整个文件夹搬移；若使用固定外部数据目录，移动程序后继续指定相同路径。数据目录专属进程锁会拒绝另一版本同时使用它，须先关闭旧版全部游戏窗口，再核对并运行新版。恢复操作始终保留原库和备份。

## 自动验证

```powershell
node tools/pack-windows.test.mjs
```

验证使用独立 D 盘数据目录，通过真实 VBS 启动链路运行 release 程序，进入主场景、登录正式测试账号并保存；服务退出后重新启动，核对同一远端角色和存档。Godot 4.7 标准 release 模板不支持 `--script`，所以测试只在独立包副本放入临时 `override.cfg` 和测试场景，再实例化原 PCK 的正式主场景。生产 PCK 的 SHA-256 保持一致，交付目录不含任何覆盖文件。它不操作当前试玩窗口或实际玩家数据库。

本次已实际通过两次直接冷启动验证：首次直接双击 VBS，由正式界面注册并登录；关闭全部窗口和服务后，再直接双击并登录同一账号，角色与保存数据保持一致。测试不会先用 `--service-test` 预热后台。真实窗口截图为包目录的 `windows-login.png`。首次启动曾发现异步日志流 fd 未就绪导致进程启动失败，现已改为同步打开数字文件句柄，并验证缺失游戏文件等启动异常会持久记录，避免仅输出至隐藏 stderr。

最终包无 override 的正常主场景也已单独启动并自动退出，真实进程退出码为 0、日志中无运行错误。随包备份/恢复 CLI、命名管道身份复用和文件清单校验一同通过；完整桌面联网多人功能仍不能仅凭登录检查视为全部通过。
