# 《按时吃饭》全剧情视觉精修验收

- 验收日期：2026-11-19
- 项目：`D:\Projects\ChatGPT\涅槃\work\xiuxian-pages`
- 分支：`codex/ptds-full-game`
- 用户授权：**全部精修，不增加 CG**。
- 结论：**九章、二十关、41 个正式剧情场景的本地视觉精修、真实 OpenGL 渲染与逐章读图验收已完成；随后发现的真实村庄入口叠加、按钮布局、刷新与正式账号演示重置问题已追加修复并复验。** 未提交、未推送、未部署官网；手机真机触屏仍未验证。

## 1. 最终画面范围

### 全场景统一

- 四十个关卡战前／战后场景及 `ending.home` 均使用真实项目角色、Boss／NPC 立绘和正式关卡背景，不再使用方块、圆形脑袋、梯形身体或空白信代替。
- 十二章透明道具单元已拆分、检查并接入：旧灯、树痕、干粮、绳结、空船、地图、双杯棋局、司南、单只热面碗、旧碗筷、同行行囊、空白旧信封。
- 每章有克制的主光与色调；主角、当前对话者和剧情物件采用统一景别与比例。终章 Boss 的外圈装饰限制在画面内，不裁切主体。
- 对话增加说话人头像与名字。非主角说话时保留对应在场角色；主角接话时保留上一位对话者，避免“刘婶说话却出现母亲”等人戏不符。
- 轻微呼吸、船体浮动、灯光变化和热气仅用于剧情表现，不改变战斗输入、数值或判定。

### 关键情绪场景

- `b12` 家书为 Godot 原生可读文字，保留“等爹回来／给你下碗面”的划改与“按时吃饭”，不是图片伪字，也不再是空白信。
- 回村结局使用三碗独立摆放的热面和一副旧碗筷；没有采用生成失败的多碗木桌或修补图。
- 回村背景避开右上角秘境光圈，视觉焦点落在母亲、主角、阿宁和饭桌上。
- 男女主角与男／女阿宁独立组合，共享同一剧情、奖励、旗标和结局。

## 2. 验证记录

| 验证 | 实际结果 |
|---|---|
| `tests/story_visual_p1_test.gd` | **1024 项断言，0 失败；41 个正式场景；9 张章节联系表** |
| 全部剧情逐句检查 | 检查每句原生对白、当场美术、说话人头像、在场角色保留及正式道具加载 |
| 九章联系表读图 | 序章、木、火、土、金、水、旁篇、共域、终章均已查看；另读家书、树痕、干粮、行囊、空船、终章棋局、回村等原尺寸图 |
| `tests/story_p0_render_test.gd` | **259 项断言，0 失败**；四种男女外观组合、场景标记、模拟触屏和五个关键 Boss 战斗角落回归通过 |
| `tests/story_live_integration_test.gd` | **24 项断言，0 失败**；真实村庄＋主 HUD＋剧情模态层、按钮不重叠、微动态刷新、隐藏停止重绘、正式账号双重禁重置均通过 |
| `tests/guest_demo_test.gd` | **10 项正常登录流程检查全部通过**；游客演示仍可独立进入、结算和退出 |
| Godot 启动检查 | 退出码 0，无脚本错误 |
| 正式道具清单 `--require-ready` | 全部资产 ready，校验通过；脚本结论不代替实际读图 |
| `git diff --check` | 无空白错误；只有既有文本换行格式提示 |

截图采用真实 OpenGL 渲染窗口。`--headless` 下等待 `frame_post_draw` 无法形成有效截图，不作为本轮图片验收路径。

## 3. 本轮保持不变

- 剧情文本与九章二十关事实源。
- 战斗数值、攻击范围、攻击判定、预警和奖励。
- 二十长廊顺序解锁、存档及场景标记规则。
- 既有开场 CG 与循环加载动画；本轮没有新增视频。
- 战斗内剧情道具仍为非阻挡边角演出，不覆盖主角、Boss 或操作区域。

## 4. 验收产物

- 全场景报告：`output/story-refined/report.json`
- 四十个关卡场景：`output/story-refined/b00-prelude.png` 至 `b19-resolution.png`
- 回村代表画面：`output/story-refined/ending-home.png`
- 回村补充画面：`ending-home-00.png`、`ending-home-06.png`、`ending-home-13.png`
- 九章联系表：`output/story-refined/chapter-origin.png`、`chapter-wood.png`、`chapter-fire.png`、`chapter-earth.png`、`chapter-metal.png`、`chapter-water.png`、`chapter-side.png`、`chapter-echo.png`、`chapter-finale.png`
- 正式道具：`assets/story_props/story-prop-atlas.png` 与 `assets/story_props/cells/`
- 全场景测试：`tests/story_visual_p1_test.gd`
- 通用回归报告：`output/story-p0-report.json`

## 5. 复现

```powershell
# 全场景与九章联系表：必须使用真实渲染窗口
& "D:\Projects\Codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe" --rendering-driver opengl3 --path "D:\Projects\ChatGPT\涅槃\work\xiuxian-pages" --script "res://tests/story_visual_p1_test.gd"

# 四组合、持久化与战斗演出回归
& "D:\Projects\Codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe" --rendering-driver opengl3 --path "D:\Projects\ChatGPT\涅槃\work\xiuxian-pages" --script "res://tests/story_p0_render_test.gd"
```

## 6. 边界

- 逐场景代表画面已人工读图，全部对白逐句由测试检查；这不冒充每一句都另存了一张人工审阅截图。
- 当前结论针对本地 Godot 工程，不代表官网已更新。
- 真机触屏、不同手机屏幕比例与手感仍需另做设备验收。
- 角色身份沿用本轮已展示及项目既有正式资产，没有另制新身份母版或新增 CG。

## 7. 真实入口追加修复（本轮实机问题）

用户实机截图暴露出独立场景测试未覆盖的村庄主 UI 叠加状态。追加修复如下：

- 三个正式剧情入口统一通过 `StoryScenePlayer.mount()` 使用 **100 层独立模态窗口**，关闭时同步销毁窗口层；不再把剧情 `Control` 直接挂到根节点并指望 `z_index` 压过主 HUD。
- 对话框改为“头像＋正文”的阅读区与独立操作栏，使用容器自适应排版；上一句、继续和正文不再依赖固定坐标，避免互相挤压。
- 可见剧情微动态刷新目标由 12 fps 调整为 30 fps；隐藏道具停止重绘。实测可见道具 0.70 秒重绘 18 次，隐藏后 0.25 秒重绘 0 次。相同插画的对白切换不再整屏淡入闪烁。
- “重置演示”仅对明确游客／本地演示开放。正式账号不显示入口；即使绕过界面直接调用，服务端角色投影的状态层也会拒绝重置并保留资源、装备和通关数据。该项目没有服务端 reset-demo 路由，本次没有新增或调用任何账号重置接口。
- 真实入口测试只使用 `--preview` 和内存账号替身，未读取、清除或重置用户正式账号。

真实入口实渲：

- `output/story-live-village-fixed.png`：真实村庄与主 HUD 存在时，剧情仍完整置顶，按钮分离。
- `output/story-live-village-next.png`：下一句保持相同插画稳定显示，无整屏闪烁。
- `output/story-live-integration-report.json`：24 项断言，0 失败。

```powershell
# 真实村庄、剧情层级、按钮布局、刷新和正式账号权限；仅用非持久化预览
& "D:\Projects\Codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe" --path "D:\Projects\ChatGPT\涅槃\work\xiuxian-pages" --script "res://tests/story_live_integration_test.gd" -- --preview

# 游客演示必须按正常登录流程运行，不能附加 --preview 跳过登录页
& "D:\Projects\Codex\tools\godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe" --path "D:\Projects\ChatGPT\涅槃\work\xiuxian-pages" --script "res://tests/guest_demo_test.gd"
```

这些结果证明本地真实 Godot 入口的已测组合，不替代用户当前账号下的人工试玩，也不代表手机真机或官网已经验证。
