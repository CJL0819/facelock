# 应用面容锁

为越狱设备（roothide）上选定的 App 加一道面容 ID 锁：打开受保护的 App 时，
在 App 自己的界面上盖一层锁屏，验证通过才放行。

- 设置 →「应用面容锁」：总开关、后台锁定时机（立即 / 30 秒 / 1 分钟 / 5 分钟 /
  10 分钟 / 不锁定）、设备锁屏时锁定，以及带搜索的 App 开关列表。
- 锁屏自动拉起面容 ID 最多 3 次，之后静默等待手动点「使用面容 ID」或「使用密码」。
- App 退到后台即上锁（按设置的时间），应用切换器里显示的是锁屏而不是内容。

## 实现要点

- `Sources/Tweak.m`：注入所有 App 与 SpringBoard。App 侧负责锁屏窗口、读取设置、
  请求验证；SpringBoard 侧是面容 ID 服务（App 进程里直接调 LocalAuthentication 会
  因为缺 `NSFaceIDUsageDescription` 被 TCC 杀掉，SpringBoard 的 entitlements 带
  `kTCCServiceFaceID`，可以正常调用）。
- App 与 SpringBoard 通过 Darwin 通知的名字状态通信：请求带 token，应答是
  `token << 1 | 是否通过`。
- 设置既写偏好文件（cfprefsd，域为包标识 `com.404.facelock`），也把「已保护」状态
  写进 `<包标识>/protected/<bundle id>` 的通知状态，App 启动时两者取「有保护」，
  不必等 cfprefsd 落盘。
- `Prefs/RootListController.m`：设置面板，固定行来自 `Resources/Root.plist`，App 列表
  由 Launch Services 生成（只列桌面可见的 App），搜索走独立的结果列表。
- `Tools/MakeIcon.m`：用 CoreGraphics 画 `apelin-icon.png` 与设置行图标。

## 构建

在设备上用 Apelin 打开这个项目，`apelin-project.json` 就是构建描述；
Build 产出 `com.404.facelock` 包，安装后重启桌面（respring）才会加载 SpringBoard 那一侧。
