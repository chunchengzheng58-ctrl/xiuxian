# 网页首屏加载动画

`game.html` 在引擎脚本和游戏资源开始下载前显示开场 MP4，播放结束、播放失败或点击跳过后显示标题卡和循环跑步动画。进度条保持使用 Godot 下载回调的真实进度；游戏启动后关闭网页加载层。

每次 Godot Web 导出后，必须执行：

```powershell
node tools/prepare-web-loading.mjs <网页导出目录>
```

将生成的 `loading/` 目录与导出的 HTML、JS、WASM、PCK 一起发布，路径相对于 HTML 的 base。视频静音自动播放，移动端使用 playsinline；不支持视频时仍显示标题卡和跑步动画。
