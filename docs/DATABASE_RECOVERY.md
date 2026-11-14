# 数据库备份与恢复

服务端账号、钱包、装备、交易、好友、私信、秘境进度和幂等回执位于 SQLite 数据库。新版提供在线一致备份和恢复命令。恢复始终生成一个全新文件，不覆盖原库，也不会自动停止或切换正在运行的服务。

## 创建备份

在 `D:\Projects\ChatGPT\涅槃\work\xiuxian-pages\server` 运行，明确指定要备份的数据库：

```powershell
npm.cmd run backup -- 'D:\Projects\ChatGPT\涅槃\work\xiuxian-pages\server\var\game.sqlite'
```

未指定输出路径时，备份保存在项目 `outputs/backups/game-<UTC时间>.sqlite`，同时生成相邻的 `.sqlite.manifest.json` 清单。命令输出两个完整路径、数据库版本、SHA-256 和各表行数，不输出账号密码或私信内容。

也可以指定全新备份路径：

```powershell
npm.cmd run backup -- 'D:\Projects\ChatGPT\涅槃\work\xiuxian-pages\server\var\game.sqlite' 'D:\Projects\ChatGPT\涅槃\work\xiuxian-pages\outputs\backups\before-upgrade.sqlite'
```

输入文件必须已经存在；目标主文件、清单或 `-wal`、`-shm`、`-journal` 附属文件存在时，命令拒绝执行。再次备份应使用新文件名。备份只读打开源库，通过 Node.js 24 自带 SQLite online backup API 获取完整快照，包含已经提交到 WAL 的数据，排除尚未提交的事务；不需要停止正常的游戏写入。不要用运行中直接复制单个 `game.sqlite` 的方式替代此命令。

清单和数据库应放在一起保存。备份包含登录凭证散列、会话和账号资料，应作为私有服务数据保存，不放入网页发布目录或公开分享。

## 恢复到新路径

先保留原服务和原库，生成可检查的恢复副本：

```powershell
npm.cmd run restore -- 'D:\Projects\ChatGPT\涅槃\work\xiuxian-pages\outputs\backups\before-upgrade.sqlite' 'D:\Projects\ChatGPT\涅槃\work\xiuxian-pages\outputs\recovery\verified-game.sqlite'
```

命令在写出结果前检查清单 SHA-256、SQLite 完整性、外键、迁移历史校验和与程序支持版本。游戏专用库的完整表、索引、视图和触发器集合必须与迁移定义一致，不允许未通过迁移添加的自定义业务对象。旧版本的升级兼容性及完整结构检查在另一份临时副本上完成，原库和原备份不会被迁移。未来版本、损坏或被修改的备份会被拒绝；作为运行库重新写入、仍有 WAL 数据的“备份文件”也不能直接用于恢复。

恢复文件同样带有清单。目标已有文件或任何相关附属文件时，程序直接拒绝，不删除、覆盖或合并这些文件。目标目录需要支持硬链接：工具先在同一目录内建立私有暂存快照，再以不可覆盖的硬链接发布，避免覆盖检查与实际写入之间的竞争。Windows 的 NTFS 目录可用；不支持时操作失败，原库仍保留。

恢复后可在独立端口验证：

```powershell
$env:DATABASE_PATH = 'D:\Projects\ChatGPT\涅槃\work\xiuxian-pages\outputs\recovery\verified-game.sqlite'
$env:PORT = '18080'
npm.cmd run dev
```

服务启动会按当前程序规则迁移这个恢复副本。确认账号、余额、行囊、交易、社交和战果符合预期后，再停止旧服务并将正式服务的 `DATABASE_PATH` 指向恢复文件。保留原库和原备份，便于核对。恢复文件开始被服务写入后，它已经是新的运行库；需要再次备份时，重新运行备份命令，不继续把它当作原来的只读快照。

恢复对应备份时刻的进度。快照之后发生的交易或聊天不会凭空重现；中途的实时战斗不包含可重放的内存房间状态。服务按中断处理这类战斗，不凭未完成的战斗发放胜利奖励。

## 已执行的恢复演练

2026-11-07 使用独立 D 盘数据库完成以下实际演练，未读取或更改正在试玩的 `server/var` 数据：

- 两个真实注册账号完成秘境战斗、获得奖励、强化和铭刻装备、建立好友关系与私信、跨账号成交，再完成一次祈愿。
- 源库包含已提交的 WAL 页面；备份期间还故意保留一笔未提交的余额修改。恢复副本保留所有已提交表记录，未提交修改没有进入快照。
- 全部账号、会话、迁移历史、钱包、装备、交易、私信、首通和幂等响应逐表核对一致。
- 恢复后重复原购买请求不再次扣费，重新读取首通战果不重复发奖；原交易装备还能再次上架和成交，强化及流派保持不变。继续交易后的测试钱包为 10 和 80 灵气。
- 已有目标、附属文件冲突、文件篡改、损坏清单、损坏 SQLite、未来版本、迁移记录篡改和被写入的备份均拒绝处理，源文件或已有目标不变。
- 当前与上一版本中的未知表、索引、视图和修改钱包语义的触发器均被拒绝；即使重新计算备份清单散列，也不能夹带未知钱包触发器恢复。
- 上一数据库版本可以生成备份及恢复副本，再由当前程序升级恢复副本；原库与备份版本保持不变。
- 战斗中备份恢复后判为服务中断、没有胜利奖励；原测试服务中的战斗仍保持运行。
- 公开排位通过实际操作击倒对手后，胜方 1012 分、负方 988 分以及战绩和榜单完整恢复。另一场正在进行的排位局恢复后中断，不计入积分；重复查看、离场和推进时钟均不重复计分。

复现自动回归：

```powershell
npm.cmd run build
node node_modules/tsx/dist/cli.mjs --test --test-concurrency=1 tests/backup.test.ts
```

该组 9 项测试全部通过。日志位于 `D:\Projects\ChatGPT\涅槃\work\commercial-verification\backup-recovery-tests.log`；测试数据及逐表恢复报告在项目 `work/backup-tests/recovery-*/recovery-summary.json`。备份和恢复 CLI 也已分别执行成功，演练日志与副本位于父目录 `work/commercial-verification/backup-cli-*/`。

本工具解决数据库一致快照与恢复副本验证。它不自动安排周期任务、复制到另一块磁盘，也不替代异地备份和长期恢复演练。客户端的灵宠偏好、旧档归档等本机资料仍需单独保留对应客户端目录。
