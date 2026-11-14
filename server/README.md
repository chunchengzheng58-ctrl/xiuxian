# C：本地游戏后端

本目录实现 Node.js 24 + TypeScript + Fastify + SQLite 服务，默认监听 `127.0.0.1:8080`，支持原生与网页客户端。游戏战斗、UI、微信与 AI 服务通过各自接口接入；当前开发验证使用独立本机服务，尚未更新远程部署。

## 启动与验证

要求 Node.js **24.13 或以上的 24.x**、npm；Godot 联调使用 4.7.2。当前使用 Node 内置 `node:sqlite`，Node 24 会输出实验性 API 提示；依赖与运行时版本须保持锁定。

```powershell
cd server
npm ci
Copy-Item .env.example .env
npm run migrate
npm run dev
```

`.env` 已忽略。D 联调时为 `HEALTH_SERVICE_TOKEN` 设置至少 32 字符的随机值；缺省时内部接口拒绝访问。可用 `node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"` 在本机生成，交给 D 的可信服务端保存。不要写入 Godot、网页、模型提示词或版本库。

- `GET /healthz`：存活检查。
- `GET /openapi.json`：从运行路由生成 OpenAPI 3 文档。
- `npm run build`、`npm start`：编译并启动本地服务。
- `npm run check`：TypeScript 编译、HTTP/数据库/权限/WebSocket 自动测试。
- `npm run demo`：独立内存数据库和随机回环端口的完整联调演示，不改变开发数据库。
- `npm run openapi`：将 OpenAPI 输出到标准输出。
- `npm run backup -- <源数据库> [全新备份路径]`、`npm run restore -- <备份数据库> <全新恢复路径>`：WAL 一致备份、校验及恢复副本；详细步骤见 [恢复指南](../docs/DATABASE_RECOVERY.md)。
- `npm run test:godot -- 'Godot控制台程序路径'`：启动隔离服务，执行真实 Godot HTTP/WebSocket 联调。
- 仓库根目录运行 `powershell -ExecutionPolicy Bypass -File tools/test_backend.ps1 -Godot 'Godot控制台程序路径'`：后端、演示、Godot 网络和现有内核回归的统一入口。

数据库默认位于 `server/var/game.sqlite`，迁移在启动时自动执行。`npm run migrate` 可单独验证迁移。测试使用内存或临时数据库，不载入玩家存档。版本高于程序或历史迁移校验不符时停止启动，禁止自动覆盖。

## 功能状态

| 能力 | 状态 |
|---|---|
| 注册、登录、会话撤销、角色归属 | 已实现；密码 scrypt，数据库仅保存会话摘要 |
| 角色、资源快照、装备与抽卡 | 已接入原生界面；角色隔离、70/700 祈愿、五档品质与累计传说保障 |
| 装备成长 | 强化 +10、三流派铭刻、2/4 件套装与分解；由共享 equipment-growth-v2 配置驱动 |
| 任务模板、实例、状态与幂等结算 | 已实现；D 提供实际验证事实 |
| 邀请、业务绑定、独立授权、撤回 | 已实现 C 服务；实际微信身份和授权交互由 D 提供 |
| 通知租约、确认、退避重试 | 已实现；D 消费并调用 iLink 回复 |
| 个人 WebSocket 快照与变更通知 | 已实现账号投影及好友论剑同步；主城同屏位置、组队尚未实现 |
| 赛季日历查询、客户端同步和旧存档指纹归属 | 已实现；健康入口通过独立凭证提交最小基线投影 |
| 战斗会话与生命周期 | 已接入角色状态、首通与确认流程 |
| 同道录和万宝集 | 已实现好友申请、私信、屏蔽与跨账号装备交易 |
| 好友实时 PvP | 约战、倒计时、服务端移动与命中、掉线重连和战果记录 |
| 公开匹配与积分 | 无需好友关系，60 秒队列、相近积分优先、权威一次性积分结算、累计公开榜 |
| 权威 PvE 秘境 | 二十 Boss、三阶段与六十招、固定预警/同源命中几何、养成快照、断线恢复及首通/再战原子奖励 |
| 主线剧情与历练 | 九章目标、对白与一次性章节奖励；story.snapshot/advance；独立30级冒险成长、五印与终章保存 |
| 微信通道、AI 识别、真实健康核验 | 本目录不实现；本地演示明确使用模拟 D |

## 模块结构

| 位置 | 职责与维护人 |
|---|---|
| `src/app.ts` | C：HTTP 装配、校验、认证和 OpenAPI |
| `src/auth.ts`、`src/database.ts` | C：账号会话、事务与数据库迁移 |
| `src/game/` | C：任务实例、账本、抽卡、快照、赛季及版本化规则接口 |
| `src/integration/` | C：绑定、D 接缝、通知；附 D 可使用的 HealthClient |
| `src/realtime/` | C：标准 WebSocket、一次性票据、个人状态隔离 |
| `tests/`、`tools/` | C：隔离测试、本地演示、Godot 联调工具 |

D 合并时可新增 `server/channels/wechat_ilink/`、`server/health/`、`server/rules/`，或保留 Python 健康服务并调用内部 HTTP 接口。原始报告、图片、健康通道聊天和识别说明不得进入游戏数据库与网络快照。同道录私信只通过会话双方鉴权后的接口查询。

## HTTP 与幂等

公共游戏请求沿用 `POST /api/v2/commands`：

```json
{
  "version": 1,
  "command": "growth.draw",
  "payload": {"cultivator_id": "c_001", "count": 1, "request_id": "draw_001"}
}
```

所有业务接口返回统一结构，失败时 data 为空对象：

```json
{"ok": false, "code": "INSUFFICIENT_FUNDS", "message": "资源不足或数值越界", "data": {}}
```

通过 `Authorization: Bearer <session>` 认证。新任务命令见共享 `data/kernel/contracts.json`。`growth.create`、`growth.equip` 使用 `Idempotency-Key` 请求头；已有 request_id 的命令沿用正文键，两处同时提供时必须相同。重试返回最初结果，同键改内容返回 IDEMPOTENCY_CONFLICT。`growth.select` 只校验并返回角色快照，客户端自行保存当前选择。

注册、登录、邀请及 WebSocket 票据签发不缓存明文秘密到幂等表。新邀请替换该角色旧邀请；确认成功后相同内容重试返回同一绑定，不重新激活已撤回授权。相同邀请不能改换微信身份。退出、解绑和撤回按其当前状态处理。

`quests.claim.quest_id` 表示**任务实例 ID**。健康任务已自动结算时返回原结算记录，不再次增加资源；尚未结算返回 NOT_CLAIMABLE。

## 联调规则与限制

当前本人和家人使用 `pixel-local-v1` 基础规则及 `equipment-growth-v2` 装备成长配置。`integration-v1` 保留给早期任务、旧式角色和兼容测试，不是聚宝阁界面的价格与品质规则。

### 公开匹配

`combat.matchmaking_lobby`、`combat.matchmaking_join`、`combat.matchmaking_cancel` 都接受 `{cultivator_id}`。加入和取消通过幂等写操作提交；随后读取 lobby 获取最新队列或对局，不能用历史写回执覆盖当前状态。本人须处于修行状态并先通过 `social.profile` 设置独立公开昵称。

匹配队列有效 60 秒，优先接近的积分，等待后扩大范围；不匹配彼此屏蔽的玩家。同一角色不能同时排队、挑战秘境或进行好友约战。没有有效账号会话、角色状态变化或服务重启时清理排队。

配对后复用 `duel_join` / `duel_input` / `duel_exit` WebSocket 和 `combat.duel_leave`。`duel_state.mode` 区分 `ranked` 与 `friendly`，匹配终态的 `rating_change` 返回 `{before,after,delta}`；好友局和不计分的终态为 `null`。积分从 1000 开始，Elo K=24，结算与对局终态同一事务且只执行一次。准备退出、未能入场、角色状态变化和服务中断不计分。排行榜仅返回公开昵称、积分和战绩。

### 当前像素游戏规则

- 角色的钱包、装备、材料、祈愿次数和传说保障计数分别保存。服务端字段 `spirit_stones` 在界面显示为「灵气」，`materials` 显示为「锻材」。
- 同角色同北京时间自然日的 `daily_plan` 奖励组最多一次：100 灵气、10 修为、1 灵印、累计有效日 +1。玩家不能自行声明可信健康事件发奖。
- 聚宝阁单抽 70、十连 700；普通/精良/史诗/传说/神话五档品质；十连至少史诗，重复装备保留为独立实例。基础概率由初始支持值冻结，详见 `data/pixel-game-rules.v1.json`。已有确认档案时使用其属性平均值；本人首次 `combat.expedition_start` 在值为空时设为固定游戏支持值 50，标识 `adventurer-default-v1`，不创建健康基线，也不覆盖既有值。
- 新版累计未出传说/神话次数保存于 `legendary_pity`。第 31 抽起对低品质结果追加逐步提升传说的机会，最多第 50 抽达到传说或以上；出传说或神话后归零。新计数从 0 开始，不反推旧祈愿历史。
- `growth.set_wish` 可选择 `school=-1`（随机）或 `0..2`（苍梧生息、白羽剑意、玄泽踏云）。选定流派只决定铭刻，不改变品质、槽位或装备模板分布。
- `growth.upgrade` 消耗锻材和灵气，最高 +10；`growth.attune` 修改铭刻；`growth.salvage` 消耗装备换锻材。强化/铭刻使用预期旧值防止过时请求重复消耗；写请求同样需要幂等键。挂单装备不能锻造；分解和上架前须卸下装备，不能重复上架。交易保留强化与铭刻。
- 同流派穿戴 2/4 件会增加 PVE 入场快照数值。好友论剑使用统一基础数值，不读取养成差异。
- `growth.market_post/cancel/buy` 使用同一命令事务管理挂单、装备归属和买卖双方账本。每角色最多 20 个在售挂单，价格范围 1–1,000,000 灵气；不能购买本账号的挂单。
- 同道录使用独立社交昵称和邀请码；仅已接受好友可私信，按会话保留最近 100 条。好友约战由服务端推进移动、技能、命中和战果，客户端只发送输入。

### 早期 integration-v1 兼容规则

以下仍在 `src/game/rules.ts` 中提供给旧任务与回归测试，不作为新聚宝阁的玩家说明：

- 照片/家属确认/自述/设备验证分别为 80%/60%/30%/100%。验证级别由可信 D 提供，不能由玩家发送。
- 灵石先乘验证与补偿倍率，再向下取整，最后截断到 UTC+8 当日剩余额度；每日暂定 30。经验只乘验证倍率。
- 同类事件以服务端结算时间计算滚动 24 小时限制；再次完成保留记录，资源为零。日灵石达到上限仍记录完成与应得经验。
- 角色创建没有已确认的健康与战力输入，补偿默认 0 档。动态补偿由后续可信 RuleProviders.compensation 接入。
- 单抽 10 灵石、十连 100；概率 60/30/9/1；十连至少灵品；仙品及以上清零仙品保底，保底阈值 80/70/60/50。
- 旧联调池按角色灵根生成四部位、四稀有度；同目录 ID 重复分别转换 1/3/10/30 材料。该旧池不使用当前像素装备铭刻与强化界面。
- 初版日历明确发布 2026 下半年与 2027 上半年，按日历边界切季。未配置后续赛季时返回 SEASON_UNAVAILABLE，不擅自重置永久积累。

模板及规则版本随任务实例固定。新增规则必须保留旧版本提供方，不能修改旧版本语义。结算故障保存待处理事实并指数退避重试；授权失效等业务错误进入 blocked，必须重新授权、复核并提交新事件，不能静默恢复旧证据。

详细接口样例、A/B/D 合并步骤、WebSocket 协议与测试标准见 [团队合并指南](../docs/BACKEND_INTEGRATION.md)。

## 试玩、数据与发布

玩家入口和多人试玩方法见 [新版试玩指南](../docs/PLAYTEST_GUIDE.md)。`server/var` 保存正式账号数据库；Godot 的 `work/appdata` 是独立客户端缓存，两者不能互相代替。数据库使用 WAL，运行中只复制 `game.sqlite` 不能作为完整备份。版本升级先验证隔离迁移及恢复；停止所有使用该数据库的服务后，才可整体复制 `server/var` 备份。

当前源码新增功能不表示现有在线页面已经更新。网页需重新导出并与对应版本的服务端联调；发布前验证范围见 [发布核对](../docs/RELEASE_READINESS.md)。
