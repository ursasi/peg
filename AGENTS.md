# Peg 开发约定

## 自动化测试脚本禁止向全局 HID tap 发送 Esc

pi 的 TUI 把 `Esc` 当作中断键（`app.interrupt`）。测试脚本若用
`CGEvent(...).post(tap: .cghidEventTap)` 全局投递 Esc（例如 `key(53)`、`/tmp/esc`），
而当时前台窗口是运行 pi 的终端，那么正在跑的 pi 运行会被 abort，日志里表现为：

```
toolResult: "Command aborted"
assistant: stopReason=error, errorMessage="This operation was aborted", durationMs=0
```

规则：

1. **优先 `postToPid`**：所有合成事件（键盘 + 鼠标）都用
   `event.postToPid(pegPid)` 只投递给 Peg 进程，绝不使用 `.cghidEventTap`。
   `pegPid` 从 `NSWorkspace.shared.runningApplications` 里按名称/bundle id 查找；
   找不到就退出并报错，不要退回全局投递。
2. **退出/取消不要模拟 Esc**：用
   `NSRunningApplication(processIdentifier: pid)?.terminate()` 或 `killall Peg`。
   需要验证「用户按 Esc 的行为」时，才用 `postToPid` 定向发送。
3. **截图验证也一样**：`/tmp/tools.swift` 是这类脚本的模板，参考它里面的
   `targetPid` + `postToPid` 写法。
4. pi 侧已把中断键改为 `Ctrl+Shift+X`（`~/.pi/agent/keybindings.json`），
   所以现在的 `Esc` 不会中断运行；但不要依赖这一点，脚本仍然必须定向投递。

## 其它

- 长会话会攒很多截图：pi 已把 deepseek 的图片档位压到 1400px / JPEG，
  并且 `~/.pi/agent/extensions/image-budget.ts` 会在请求前把过老的图换成文字占位符。
  单次请求上限约 50 MB，超过会收到 `413 Failed to buffer the request body`。
