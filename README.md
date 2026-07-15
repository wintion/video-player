<p align="center">
  <img src="docs/assets/rawya-mark.svg" width="160" alt="Rawya Logo">
</p>

<h1 align="center">Rawya</h1>

<p align="center">简洁、现代的 macOS 本地音视频播放器</p>

<p align="center">
  <a href="https://github.com/wintion/video-player/releases">下载</a> ·
  <a href="https://github.com/wintion/video-player/issues">问题反馈</a>
</p>

## 简介

Rawya 专注于 macOS 本地媒体播放体验，提供清晰易用的操作界面，同时保留面向进阶用户的播放与显示设置。

## 主要功能

- 播放常见视频和音频格式
- 字幕、播放列表和章节管理
- 画中画与音乐模式
- 视频缩略图和播放历史
- 音频、视频与字幕参数调整
- 自定义键盘、鼠标、触控板和手势操作
- 支持高级播放配置与扩展能力

## 系统要求

- Intel Mac：macOS 10.15 或更高版本
- Apple 芯片 Mac：macOS 12 或更高版本

## 下载

正式发布版本请前往 [Releases](https://github.com/wintion/video-player/releases) 页面下载。

开发构建仅用于本地测试，不建议直接作为正式分发版本。

## 本地构建

1. 安装最新版 Xcode。
2. 下载项目依赖：

   ```bash
   ./other/download_libs.sh
   ```

3. 使用 Xcode 打开仓库中的 `.xcodeproj` 工程。
4. 选择主应用 Scheme 和目标架构后执行构建。

当前发布分支基于稳定的 `1.4.4` 版本维护。后续升级继续以稳定版本为基线，具体约定见[上游版本策略](docs/upstream-release-strategy.md)。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE) 许可证。项目包含的第三方代码、库和资源保留其各自的版权声明与许可条款。
