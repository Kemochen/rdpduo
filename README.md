# DuoRDP

DuoRDP 是一个面向 iPhone Duo 的 RDP 客户端构建项目。它固定使用 FreeRDP 3.28.0，添加 iPhone Duo 折叠区域适配，并通过 GitHub Actions 生成可由 AltStore 重签和安装的未签名 IPA。

## 当前功能

- Windows RDP 连接、NLA/TLS 登录和 RD Gateway 基础能力由 FreeRDP 提供。
- Metal 远程桌面渲染、触摸输入、软键盘及外接键鼠。
- 支持 iPhone 横竖屏、外屏和完全展开的内屏尺寸变化。
- iOS 27.1 及以上使用 `UIViewReservedRegion` 检测活动折痕。
- 书本姿态选择折痕一侧显示桌面；笔记本姿态优先在折痕上方显示桌面。
- GitHub Actions 在 arm64 iOS Device 模式下打包未签名 IPA，不需要把证书上传到 GitHub。

应用最低部署版本是 iOS 15；iPhone Duo 专用折叠适配仅在 iOS 27.1 及以上启用。

## 在 GitHub 编译

1. 在 GitHub 新建一个空仓库，将此目录中的文件推送到仓库的 `main` 分支。
2. 打开仓库的 **Actions** 页面。
3. 选择 **Build DuoRDP IPA**，点击 **Run workflow**。
4. `bundle_id` 可以保留默认值，也可以改成类似 `com.你的名字.duordp` 的唯一标识。
5. 构建完成后，在运行页面底部下载 **DuoRDP-unsigned-ipa** artifact。
6. 解压 artifact，里面的 `DuoRDP-*.ipa` 就是 AltStore 所需文件。

第一次构建会从官方仓库下载 FreeRDP 及 OpenSSL，并在 GitHub 的 Xcode 27 runner 上编译，通常明显慢于普通 iOS 项目。

## 用 AltStore 安装

1. 确保 iPhone 上的 AltStore 能正常刷新应用。
2. 将 IPA 保存到“文件”App。
3. 在 AltStore 的 **My Apps** 页面点击左上角 `+`，选择 IPA。
4. AltStore 会使用你的 Apple ID 重签后安装。

免费 Apple ID 安装的应用通常需要每 7 天刷新，并受到 AltStore/Apple 的活动应用数量限制。GitHub 产物本身没有签名，不能直接点击安装。

## 第一版限制

- 为降低 GitHub 构建时间和故障率，工作流暂时关闭 FFmpeg、OpenH264、Opus、Azure 登录和额外图片编解码器。普通 Windows RDP 会协商到基础图形通道。
- 折叠时目前把远程桌面限制在一个可用区域；另一侧触摸板/快捷键控制面板属于下一阶段。
- 此 Windows 工作区无法运行 Xcode 或 iPhone Duo 模拟器。最终编译和设备级验证由 GitHub 的 `xcode-27` runner 以及你的真机完成。
- 请只连接你拥有或获准管理的计算机。

## 项目结构

- `.github/workflows/build-ipa.yml`：GitHub Actions IPA 构建工作流。
- `scripts/build-ipa.sh`：下载、配置、编译和打包脚本。
- `patches/freerdp-3.28.0-iphone-duo.patch`：Duo 布局、应用名称和 Bundle ID 定制。

## 上游与许可证

FreeRDP 项目使用 Apache-2.0；它的部分 iOS 客户端源码带有 MPL-2.0 文件级许可证。本仓库的补丁不会移除任何上游版权或许可证声明。构建时使用的准确上游版本为 `3.28.0`。
