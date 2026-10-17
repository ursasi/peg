# Peg

> 截图，夹在屏幕上。

macOS 菜单栏截图工具，把 Snipaste 的「截图 → 标注 → 贴图」、PixPin 的「长截图」和
Tendedero 的「截图晾衣绳」揉进一个 app。**只为自己用**，所以没有账号、没有网络、
没有分析、没有更新器，也没有废话。

```
⌃⌥X   截图（冻结全屏 → 拖拽选区 → ⏎ 复制并保存 / P 贴到屏幕 / Esc 取消）
⌃⌥S   收起 / 放下晾图绳
```

## 现在能做什么（v0.1）

| 能力 | 状态 |
|---|---|
| 全屏冻结 + 拖拽选区（消除闪烁、不会把遮罩拍进去） | ✅ |
| 像素级放大镜：放大画面 + 坐标 + 取色 + HEX | ✅ |
| 选区尺寸实时显示（真实像素，Retina 已换算） | ✅ |
| 拖拽后 ⏎ 复制到剪贴板，同时存 `~/Pictures/Peg/` | ✅ |
| 双击选区内部直接复制 | ✅ |
| `P` 把选区贴成置顶窗口：拖动移动、滚轮缩放、右键菜单、Esc 关闭 | ✅ |
| 晾图绳：截图自动挂到屏幕顶部，指针贴到屏幕最上沿滑出 | ✅ |
| 晾图绳交互：单击复制、双击打开、右键菜单、拖进任何 App / 文件夹 | ✅ |
| 滚动长截图 | ⏳ 下一步 |
| OCR / 录屏 / 标注编辑器 | ⏳ 后续 |

## 安装

```bash
cd ~/opensource/peg
bash scripts/build-app.sh          # 产出 build/Peg.app
cp -R build/Peg.app /Applications/ # 建议放进 /Applications，TCC 身份更稳定
open /Applications/Peg.app
```

首次按 `⌃⌥X` 会要求「屏幕录制」权限：

1. 弹窗里点「打开系统设置」；
2. 在「隐私与安全性 → 屏幕录制」勾选 Peg；
3. 回菜单栏点「重新启动 Peg」（或退出重开）。

> **为什么每次重新编译都要重新授权？**
> 脚本优先用你机器上的开发者证书签名；没有证书时退回 ad-hoc 签名，而 ad-hoc
> 签名的二进制每次编译哈希都变，TCC 会当成新 app。装个自签名证书
> （钥匙串 → 证书助理 → 创建证书 → 代码签名）就能一劳永逸。

## 用法细节

- **选区**：一次只在一个屏幕内框选（跨屏拼接涉及不同缩放比合成，先不做）。
- **取消**：`Esc` 或右键。
- **贴图**：`P`。贴图窗口不抢焦点、在所有桌面可见；双击关闭。
- **晾图绳**：把指针杵到屏幕最上沿（menu bar 顶端）1–2 像素处，绳子滑下来；
  指针离开就自动收起。也可以 `⌃⌥S` 手动开关。
- **图片目录**：`~/Pictures/Peg/`，晾图绳显示最近 24 张，删除用右键「移入废纸篓」。

## 代码结构

```
Sources/Peg/
  main.swift          NSApplication 启动（accessory，仅菜单栏）
  AppDelegate.swift   状态栏菜单、全局热键绑定
  HotKey.swift        Carbon RegisterEventHotKey（免辅助功能权限）
  Permissions.swift   屏幕录制权限的申请与引导
  Capture.swift       ScreenCaptureKit 逐屏原生分辨率单帧抓取
  SnipSession.swift   一次截图的完整生命周期：冻结 → 选区 → 裁剪 → 交付
  SelectionView.swift 遮罩、选区、角标、尺寸标签、放大镜、取色
  PixelSampler.swift  RGBA 像素快照，给放大镜取色用
  PinWindow.swift     贴图窗口
  Shelf.swift         晾图绳的数据与滑出/收起
  ShelfView.swift     晾图绳的 SwiftUI 界面
  ImageActions.swift  剪贴板、落盘、缩略图
  Demo.swift          `PEG_DEMO` 用的假画面
```

设计上的三个取舍：

1. **先冻结再画遮罩**，而不是边截边画。这样遮罩永远不会进图，放大镜读的是真像素，
   拖动时也没有实时采集的延迟。
2. **所有坐标以点为单位、以左上为原点**（`isFlipped = true`），只在裁剪那一刻乘
   `image.width / screen.width` 换算成像素，避免多屏 + Retina 的经典错位。
3. **热键走 Carbon**，晾图绳靠 0.09s 轮询指针位置（不用全局事件监听，也不需要辅助功能
   权限），所以整个 app 除了屏幕录制之外不要任何授权。

## 开发

这台机器的 Command Line Tools 里 SwiftPM 依赖的 BuildServerProtocol 坏了
（`Symbol not found: ...SourceKitInitializeA12ResponseData...`），所以构建脚本
绕开 SwiftPM，直接用 `swiftc` 编译所有源文件。

```bash
bash scripts/build-app.sh          # 编译 + 打包 + 签名
PEG_DEMO=shelf  ./build/Peg.app/Contents/MacOS/Peg   # 直接展开晾图绳
PEG_DEMO=overlay ./build/Peg.app/Contents/MacOS/Peg  # 假画面 + 预置选区，验证 UI
PEG_DEMO=overlay PEG_DEMO_EMPTY=1 ...                # 假画面 + 未选区状态
PEG_DEBUG=1   ./build/Peg.app/Contents/MacOS/Peg      # 打印晾图绳的指针轮询日志
```

`PEG_DEMO=overlay` 不需要屏幕录制权限，用来调界面很方便。

## 路线图

1. **滚动长截图**：手动滚动采样 + 自写拼接（重叠区行差、粗搜→精搜、粘性页眉页脚
   只保留一次、重复内容歧义拒绝）。这是三个软件拼起来最值钱的一块。
2. 标注编辑器：矩形 / 箭头 / 文字 / 马赛克 / 高斯模糊 / 撤销，截图和贴图共用一套画布。
3. OCR：Vision `RecognizeTextRequest`，可选接大模型做翻译。
4. 录屏 → GIF / MP4：`SCStream` + `SCRecordingOutput`。
5. 元素吸附：`AXUIElementCopyElementAtPosition` 自动贴合窗口与控件（需辅助功能权限）。

## 许可

MIT（见 LICENSE）。

灵感来自 [Snipaste](https://www.snipaste.com/)（闭源，仅参考交互）、
[PixPin](https://pixpin.cn/)（闭源，仅参考功能）和
[Tendedero](https://github.com/alejandrobujan/tendedero)（MIT，"晾衣绳"这个交互的出处）。
本项目没有使用它们的任何代码或图标。
