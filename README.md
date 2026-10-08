# 外接屏亮度 · ExternalBrightness

一个为本机编写的 macOS 菜单栏工具，用键盘上的亮度键调节外接显示器。安装后默认启用，并在登录时自动启动。

当前版本：**1.1.2**。已验证的设备为 **M2 Mac mini、macOS 27.0.1、LG ULTRAFINE 和 Logitech MX Keys**。安装包适用于 Apple Silicon；其他显示器与系统版本尚未验证。

## 安装

1. [下载完整安装包](ExternalBrightness-v1.1.2-macOS-arm64.zip?raw=true)，解压。
2. 双击解压目录中的 `install.command`，或在终端进入该目录后执行 `bash install.command`。
3. 首次使用时，在「系统设置 → 隐私与安全性 → 辅助功能」开启「外接屏亮度（ExternalBrightness）」。
4. 按键盘上两个太阳图标的亮度键，或使用菜单栏太阳图标中的滑块。

程序安装到 `~/Applications/ExternalBrightness.app`。安装脚本会启动程序并启用登录自启；升级时会为原有同名程序保留带时间戳的备份。

安装包使用临时签名，尚未经过 Apple 公证。若 macOS 阻止打开，请检查源码后，按系统提供的「打开」或「仍要打开」流程操作。

## 亮度范围

- 最低档位只保留 **1%、5%**；扩展亮度中的 **0%、2%、3%、4% 已删除**。
- 普通亮度键从 5% 直接降到 1%；从 1% 增亮时直接到 5%。在 1% 继续按减键会保持 1%。
- 较高亮度可继续调到 100%；普通调节每次约 6%，精细调节每次约 1%。
- 菜单滑块在 1% 与 5% 之间吸附到这两个可用档位。

| 显示的亮度 | 调节方式 |
| --- | --- |
| 20–100% | 调节显示器的硬件背光，从硬件最低值到最高值 |
| 5–20% | 在最低硬件背光上继续软件调暗 |
| 1% | 最暗可见档位，使用 95% 的黑色遮罩 |

1% 和 5% 都使用最低硬件背光；5% 的黑色遮罩为 75%。屏幕仍然通电，光标保持可见。软件亮度百分比不代表功耗百分比，两档实际功耗没有用功耗仪测量。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 调节亮度 | 键盘亮度减键 / 增键，可长按 |
| 精细调节 | Shift + Option + 亮度键 |
| 备用调节 | Control + Option + ↓ / ↑ |
| 恢复最高亮度 | Control + Option + Command + ↑ |

菜单中也可恢复亮度、暂停键盘控制、关闭登录自启。如果 MX Keys 只发送普通 F1 / F2，可在菜单中启用「F1 / F2 同时用于亮度」，或用 Fn + Esc 切换 Fn 锁。

退出、暂停控制、失去按键权限或切换到登录界面时，程序会解除软件调暗。

## 从源码编译

需要 Apple Silicon Mac 和 Xcode 命令行工具。在仓库目录中执行：

```bash
bash build.command
bash install.command
```

也可以直接执行 `bash install.command`；没有已编译的 `.app` 时，安装脚本会先调用编译脚本。卸载程序及登录启动项：

```bash
bash uninstall.command
```

卸载会保留偏好和诊断文件。

## 诊断与验证

```bash
APP="$HOME/Applications/ExternalBrightness.app/Contents/MacOS/ExternalBrightness"
"$APP" --status
"$APP" --diagnose
"$APP" --self-test
```

`--set-visual 1`、`--set-visual 5` 以及 5–100% 的其他值控制扩展亮度；0%、2%、3%、4% 会被拒绝。`--set 0...100` 是独立的硬件背光入口，硬件读回 0 并不表示保留了扩展亮度的全黑档位。`--restore` 恢复最高亮度。

本机已通过 **43 项按键解析、范围与档位检查**，以及 **15 项运行检查**，包含 1% / 5% 切换、按键连续调节、窗口遮罩、硬件背光读回和命令范围校验。完整记录见 [验证结果.json](验证结果.json) 和 [使用说明.txt](使用说明.txt)。

其他显示器、物理拔插、睡眠唤醒、其他应用全屏空间和菜单滑块的实际鼠标拖动尚未在本次验证。独立 Carbon 备用热键路线也未列为已验证。

## 仓库内容

- `Source/`：完整 Swift 源码。
- `build.command`、`install.command`、`uninstall.command`：编译、安装和卸载脚本。
- `ExternalBrightness-v1.1.2-macOS-arm64.zip`：完整应用、源码、脚本与说明，保留可执行权限。
- `SHA256SUMS`：仓库文件的 SHA-256 校验值。
- `THIRD_PARTY_NOTICES.txt`：第三方许可与来源说明。

硬件背光接口和调暗方案参考 [MonitorControl](https://github.com/MonitorControl/MonitorControl)，相关 MIT 许可见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。
