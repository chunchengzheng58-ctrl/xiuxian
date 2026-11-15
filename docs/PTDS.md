# PTDS 穿戴数据接入

《疯狂修仙，中》可在桌面客户端预览 PTDS 中的 Oura 单日步数和睡眠时长。Mac 上的导出工具通过 PTDS v0.3.0-alpha.2 的本机只读接口读取指定日期。Windows 和 Mac 上的游戏读取同一格式的摘要文件。游戏窗口关闭后清除预览，数值只供本人查看，与游戏奖励、健康评分及家人档案分开。

## 1. 在 Mac 上配置 PTDS

在 [PTDS v0.3.0-alpha.2 发布页](https://github.com/osszhaoke/ptd-substrate/releases/tag/v0.3.0-alpha.2)按说明校验并安装。记下实际的本机端口和本人数据空间的实例 key（从 PTDS 数据页 URL 的 `key` 参数或其空间配置中查看）。端口常用值为 8780。按 [Oura 接入指南](https://github.com/osszhaoke/ptd-substrate/blob/v0.3.0-alpha.2/docs/guides/oura.md)由本人配置、授权和同步。

该版本的 [Garmin 指南](https://github.com/osszhaoke/ptd-substrate/blob/v0.3.0-alpha.2/docs/guides/garmin.md)与 [Whoop 指南](https://github.com/osszhaoke/ptd-substrate/blob/v0.3.0-alpha.2/docs/guides/whoop.md)都将伙伴试用限定为只读接入检查。这两个品牌暂时没有游戏导出入口。

## 2. 导出一个日期

在 Mac 上打开本项目目录，用 Python 3 运行下方命令，将实例 key、日期和端口换成你的值：

```sh
python3 tools/export_ptds_summary.py --port 8780 --space YOUR_SPACE_KEY --date 2026-11-07 --output ptds-summary.json
```

工具只请求 `/api/data/read` 的 `data-read/1` 序列视图，并限定来源 `DEVICE_OURA`、指定日期及指标 `OURA_STEPS`、`OURA_TOTAL_SLEEP`。摘要只含版本、日期和可用的两项数值。任一查询失败时，命令退出并给出错误。两项均无记录时不生成文件；只有一项时仍可查看。每次导出请使用新的文件名。

## 3. 在游戏里打开

如在另一台电脑玩，请自行复制摘要 JSON。用 Godot 从本仓库 `main` 启动桌面版，进入仙村，打开「每日修行」→「PTDS 穿戴摘要」→「选择摘要 JSON」，即可看到步数和睡眠分钟数。游戏不会把文件发送到游戏服务器。摘要是本机健康数据，请由本人决定文件的保存位置和是否传输。

现有 Releases 中的旧试玩包和 GitHub Pages 需要从包含此功能的源码重新构建后才会出现入口。
