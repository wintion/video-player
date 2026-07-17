# AI 字幕生成与翻译路线图

## 目标

在播放器内完成“无字幕视频的字幕生成与翻译”，优先使用 Apple 原生本地能力；在不可用或用户选择时使用云服务；最后以 whisper.cpp 作为本地兜底。播放不需要等待完整转写完成，后台提前缓存未来几分钟字幕，并在播放到对应位置时通过 mpv 原生字幕轨显示。

## 总体架构

按能力层拆分，避免把 Apple、OpenAI、阿里、whisper.cpp 做成互相重复的闭环。

```text
MediaContext
 -> AudioExtractor
 -> Transcriber
 -> Translator
 -> SubtitleAssembler
 -> SubtitleCache
 -> SubtitleLoader
```

核心原则：

- 本地优先：默认优先 Apple Speech + Apple Translation。
- 云端显式授权：首次使用 OpenAI/阿里等云服务前明确提示会上传音频或文本。
- 可组合：允许 Apple 转写 + 云翻译、whisper.cpp 转写 + Apple 翻译等组合。
- 缓存优先：同一媒体、音轨、语言、引擎、模型版本命中缓存后直接加载字幕。
- 播放不中断：seek 到未生成区域时提高该区域任务优先级，不暂停播放。

## 里程碑

### M0：架构与能力探测

当前状态：已完成。核心数据模型、任务状态机、Provider 协议、可注入能力探测、缓存键/目录契约和播放器调试日志已落地；真实语言资源探测由对应 adapter 在 M2-M4 完成。

交付：

- 定义统一的 AI 字幕任务状态机。
- 定义 Transcriber、Translator、ProviderSelection 等协议。
- 实现能力探测：macOS 版本、Apple Speech/Translation 可用性、云 API Key、whisper 模型状态。
- 明确缓存键与产物目录结构。

完成标准：

- 播放器能判断当前机器“推荐使用哪个方案”。
- 不启动真实转写，也能在日志/调试入口看到 provider selection 结果。

### M1：字幕生成基础链路

当前状态：已完成。已实现 60 秒音频分块与 overlap 规划、FFmpeg 库内 16 kHz mono WAV 抽取、时间轴去重、VTT/SRT、原子缓存、缓存自动加载及 mpv reload 节流；mock 调度链路已通过 130 秒三分块自检。

交付：

- FFmpeg 音频分段抽取，输出 16k mono WAV/PCM。
- 内部字幕时间轴模型。
- VTT 写入器和基础 SRT 导出器。
- mpv 字幕加载与低频 reload。
- 缓存目录与 metadata.json。

完成标准：

- 给定一个 mock transcript JSON，可以生成 VTT 并自动加载到当前播放器。
- 同一视频第二次打开能从缓存加载。

### M2：Apple 本地主方案

当前状态：代码和首轮真机验证完成。Apple Speech/Translation adapter、异步语言能力探测、Speech `downloadAndInstall()`、Translation SwiftUI `translationTask` 可见 sheet、未来 5 分钟 ahead-window 调度、seek 重排、FFmpeg 阻塞 I/O 中断和播放器生命周期取消已实现。资源准备入口会先向用户确认，再允许 macOS 下载所选语言资源。已在 macOS 26.5.2 上完成简体中文到英文、日语到英文的本地端到端验证，覆盖资源安装、转写、翻译、VTT/SRT 缓存和播放器字幕轨加载。

交付：

- Apple SpeechAnalyzer/SpeechTranscriber 转写 adapter。
- Apple TranslationSession 翻译 adapter。
- 语言可用性检查、授权引导、语言资源不可用提示。
- 按当前播放位置维护 ahead window。

完成标准：

- macOS 26+ 上，本地完成转写和翻译。
- 播放中能持续生成未来 3-5 分钟字幕。

### M3：云服务方案

当前状态：代码完成，真实计费调用待确认。OpenAI 使用 `whisper-1` 分段时间戳和 Responses API 结构化翻译；阿里云使用 Paraformer、机器翻译 ROA 签名以及 DashScope 48 小时临时音频存储。API Key/AccessKey 存入 Keychain，并可在面板内二次确认后移除；云上传必须显式勾选许可，面板展示预估费用。Apple 不可用时支持用户预先选择 OpenAI、阿里或 whisper.cpp 自动降级，默认仍为询问，云降级继续受凭证与上传许可门控。所有 HTTP 链路支持播放器停止时取消。阿里官方将 DashScope 临时存储定位为开发和低并发用途，生产规模化需注入正式 OSS publisher。

交付：

- OpenAI 转写 adapter。
- OpenAI 翻译 adapter。
- 阿里云 Paraformer 转写 adapter。
- 阿里云机器翻译 adapter。
- Keychain 存储 API Key。
- 云端隐私提示和单次任务预计成本提示。

完成标准：

- 用户可在设置里选择 OpenAI 或阿里云。
- Apple 不可用时可自动降级到用户选择的云服务。

### M4：whisper.cpp 本地次方案

当前状态：代码完成，真实模型验证待确认。已实现 `whisper-cli` 和 `.bin` 模型导入、SHA-256 校验、模型发现/选择持久化/删除、JSON 时间戳解析、进程启动竞态取消与真实子进程终止测试，以及与 Apple/OpenAI/阿里翻译组合。未自动下载可执行文件或大模型。

交付：

- whisper.cpp 可执行文件发现/下载策略。
- 模型管理：下载、校验、删除、选择模型。
- whisper 转写 adapter，支持取消和进度回报。
- 与 Apple/云翻译组合。

完成标准：

- 无网络、Apple Speech 不可用时，可以本地转写。
- 模型未安装时有清晰引导，不阻塞播放器主流程。

### M5：产品化体验

当前状态：代码和 Apple 主路径点击流验证完成。已实现播放器字幕菜单、无字幕一次性提示、统一生成面板、provider/语言/翻译器选择、Apple 语言资源准备、Keychain 凭证输入、云上传许可、成本和进度状态、2 GB 默认 LRU 缓存上限、非当前缓存清理、VTT/SRT 导出，以及英文/简体中文/繁体中文主要入口文案。音频语言和字幕语言名称按 Rawya 当前界面语言动态本地化，底层仍保存稳定语言代码。使用项目现有签名配置构建并运行后，已确认中/日语资源准备、生成状态、字幕轨自动加载、播放画面字幕显示、冷启动缓存复用、已有字幕不提示、云服务未授权门控、窗口关闭取消，以及 VTT/SRT 导出回载。AI 面板导出会先收起配置 sheet 再显示保存面板，避免保存界面被配置面板遮挡。云服务未发起真实网络或计费调用。

交付：

- 字幕菜单入口：生成 AI 字幕、目标语言、导出字幕。
- 无字幕时自动提示。
- 生成状态 UI：准备中、已缓存到哪一段、错误与重试。
- 设置页：默认 provider、目标语言、缓存大小、云 API Key。
- 导出 VTT/SRT。

完成标准：

- 用户无需离开播放器即可完成生成、加载、缓存、导出。
- 所有云端路径都有明确授权与可关闭入口。

### M6：测试、性能与发布

当前状态：自动化部分、Apple 短视频真机矩阵和 8 分钟合成长媒体验证完成，其余真实矩阵待确认。`scripts/test_ai_subtitles.sh` 可复现覆盖 provider 选择、语言等价、Apple 不支持语言、无字幕提示策略、音轨隔离缓存键和淘汰、亚毫秒 mtime 缓存往返、VTT/SRT、分块调度、缓存恢复、EOF 首次生成、seek 重排与连续缓存状态、抽取中取消与临时文件清理、失败后重启恢复、两小时媒体仅预取五分钟、1 万 cue 性能护栏、云网络失败与临时上传回收、OpenAI/阿里云未授权时零 HTTP 请求、DashScope 临时上传 + Paraformer 模拟链路、阿里签名固定向量、whisper 缺模型门控、输出解析和 HTTP/子进程取消。常规窗口关闭、应用退出和 mpv 主动关闭现均会取消 AI 字幕任务；真实窗口关闭点击流已确认任务停止且无临时 WAV。完整 Debug 构建通过，AI 字幕新增代码无编译警告；显式 `MACOSX_DEPLOYMENT_TARGET=10.15` 构建通过，Speech、Translation、`_Translation_SwiftUI` 均验证为 `LC_LOAD_WEAK_DYLIB`。真实中/日语短视频、Apple 资源、暂停预取、无音轨门控、双音轨切换、5 分钟预取、seek 优先级、云未授权表单和 VTT/SRT 导出回载已验证；真人长视频、付费云、whisper 模型、电量和发布签名验证仍需后续资源与确认。

交付：

- 单元测试：缓存键、VTT/SRT、provider selection、时间轴合并。
- 集成测试：短视频、本地长视频、seek、暂停、换音轨、无音轨。
- 性能测试：CPU、内存、电量、磁盘缓存上限。
- 失败恢复：网络失败、授权拒绝、语言不可用、模型缺失。

完成标准：

- 长视频播放时 UI 无明显卡顿。
- seek/cancel/close window 不留下后台任务或临时文件泄漏。

## 2026-07-17 Apple 真机实测

环境：macOS 26.5.2，Apple Silicon，项目现有 Automatic signing 配置，Debug 产物使用 `Sign to Run Locally`。测试媒体由系统 `Tingting` 和 `Kyoko` 语音生成，再通过 `scripts/generate_ai_subtitle_test_video.swift` 封装为本地 MOV；测试过程没有调用云 API 或上传媒体。

结果：

- 简体中文到英文：Apple Speech 生成 11 个时间片，Apple Translation 合并为 3 条英文 cue，覆盖 0 到 15.331 秒；VTT/SRT 写入成功并在播放器 0 秒位置显示。
- 日语到英文：Apple Speech 生成 5 个时间片，Apple Translation 生成 4 条英文 cue，覆盖 0 到 14.688 秒；VTT/SRT 写入成功并在播放器 0 秒位置显示。
- 资源准备：中文、日语和英语语言资源均通过应用内确认后由 Apple 系统界面下载；完成后 `SpeechTranscriber` 与 `LanguageAvailability` 探针均返回可用。
- 缓存复用：冷启动重新打开日语媒体后自动加载 `translated.vtt`，缓存 metadata 修改时间不变，没有重复转写，也没有残留 WAV。
- 实测修复：首次在播放结束位置点击生成时原调度器会直接进入 `maintaining`。现已将 EOF 首次启动归一化为从 0 秒生成，并加入自动化回归测试。
- 长媒体与 seek：8 分 09 秒日语合成媒体首次只生成 `[0,300]` 秒；seek 到 6 分钟后优先增加 `[360,488.785]` 秒，没有顺序补齐 5 到 6 分钟，符合当前播放位置优先策略。
- 性能快照：对独立长媒体副本生成首个 5 分钟窗口时采样 150 次，进程平均 CPU 约 4.4%、峰值约 22.6%，RSS 峰值 214.7 MiB，完成后空闲 RSS 约 214.3 MiB。该数字只代表本机、Debug 构建和合成语音，不替代发布构建与电量测试。
- 缓存精度修复：复制的长媒体带亚毫秒 mtime，原先 metadata JSON 往返后的 `Date` 精度差会让面板误判不可导出。缓存验证现统一比较毫秒粒度 `stableIdentifier`，自动化和冷启动 UI 均已复验。
- 连续范围状态修复：seek 形成多个不连续缓存区间时，原状态会把首段起点和末段终点拼成一个范围。面板现只展示包含当前播放位置的连续缓存段；不连续长视频缓存从 00:33 启动时真实 UI 显示到 05:00，seek 回归测试也验证不会跨空档虚报覆盖。
- 暂停与音轨切换：暂停在 00:31 时 Apple 仍可完成未来 5 分钟预取。8 分钟双音轨 MOV 从音轨 1 切换到音轨 2 后任务立即进入 `Canceled`，无 WAV 残留；随后分别生成的缓存记录 `audioTrackID/streamIndex` 为 `1/0` 和 `2/1`，不会串轨。
- 无音轨门控：12 秒纯视频经 AVFoundation 确认为 0 个音频轨，播放器未弹出 AI 字幕建议，生成面板按钮保持禁用。测试素材生成器现支持单音轨、多音轨和指定时长静音视频。
- 已有字幕门控：播放器的延迟提示条件已提取为可测试策略；自动化覆盖内嵌/外挂字幕轨、可复用 AI 字幕缓存、无音轨、播放停止、媒体切换、关闭提示和同一媒体不重复提示。真实 UI 在开启“缺字幕时建议生成”后打开带同名 SRT 的媒体，等待后未弹出 AI 建议，字幕菜单正常显示 `#1 with-subtitles.srt subrip`。
- 网络失败恢复：自定义 `URLProtocol` 已验证系统网络错误映射为可恢复的 `cloud_network_failed`；内存 transport 覆盖 OpenAI 转写/翻译、阿里临时上传凭证、转写提交和翻译失败，并确认失败请求会从取消队列释放、阿里已发布临时音频会立即回收。测试未访问外网。
- 语言不可用：本机 Apple API 对无效语言 `zz-ZZ` 的 Speech 探测返回不支持，Translation 探测返回 `unsupported`，均未触发资源下载。执行路径现把不支持的 Speech 语言和 Translation 语言对映射为明确的不可恢复错误，不再把 Translation 的不支持状态误报为“资源未安装”。
- 关闭取消：修复普通窗口关闭仅停止 mpv、未取消 AI 字幕任务的问题；`stop()` 与 mpv 主动 shutdown 现在都调用统一的幂等取消，应用退出原有取消保持不变。调度器、HTTP task 和 whisper 子进程的取消与临时 WAV 清理已有自动化覆盖。真实 UI 在 8 分钟媒体已缓存到约 5 分钟且仍处于转写状态时关闭播放窗口，进程 CPU 回落到约 0.1%，不再持有媒体或 WAV，只保留已完成的可复用缓存片段。
- 云授权拒绝：自动化已验证 OpenAI、阿里云转写及阿里云翻译在未授权时均返回明确错误，且不会产生任何 HTTP 请求。真实 UI 分别选择 OpenAI 和阿里云，在凭证为空且上传许可未勾选时点击生成，只显示明确授权提示且未启动任务；本轮没有调用付费 API 或上传媒体。
- 导出回载：真实 UI 使用 Apple 日语到英语缓存分别导出 WebVTT 和 SRT，文件头、序号和时间戳格式正确；重新加载后播放器同时显示 `exported.vtt webvtt` 与 `exported.srt subrip` 轨道。面板导出曾因现有配置 sheet 占用播放器窗口而不显示保存 sheet，现改为先收起配置面板再异步打开保存面板，并在最新 `Sign to Run Locally` 构建中复验导出内容一致。
- whisper.cpp 缺模型：自动化已验证已发现可执行文件但未选择模型时返回下载/配置提示，并且不会启动本地子进程；真实模型准确率与性能仍待用户允许下载或提供模型后验证。
- 质量观察：日语合成语音识别较完整；中文首句存在断词和翻译不自然。实测发现的纯标点短 cue 和 ASCII 标点前多余空格已在时间轴组装层修复并加入回归测试；后续仍需用真人语音样本补充准确率基线。

## Issue 拆分

### AI-SUB-001：定义 AI 字幕核心数据模型与状态机

范围：

- `AISubtitleJob`
- `AISubtitleSegment`
- `AISubtitleCue`
- `AISubtitleTaskState`
- `AISubtitleProviderPlan`

验收：

- 能表达 preparing、extracting、transcribing、translating、assembling、loading、maintaining、completed、failed、canceled。
- 支持记录当前生成窗口和 ahead buffer 覆盖范围。

依赖：无。

### AI-SUB-002：Provider 协议与能力探测

范围：

- `AISubtitleTranscriber`
- `AISubtitleTranslator`
- `AISubtitleCapabilityDetector`
- provider selection 规则。

验收：

- 能输出推荐链路：Apple、OpenAI、Aliyun、whisper.cpp、或 unavailable。
- Apple 能力检测必须使用 availability guard，不影响旧 macOS 编译。

依赖：AI-SUB-001。

### AI-SUB-003：缓存键与缓存存储

范围：

- 缓存目录：`~/Library/Caches/<bundle-id>/ai_subtitles/`
- `metadata.json`
- `transcript.json`
- `translated.vtt`
- 缓存清理策略。

验收：

- 缓存键包含媒体路径/URL、文件大小、mtime、音轨 ID、源语言、目标语言、转写引擎、翻译引擎、模型版本。
- 命中缓存时无需重新抽音频。

依赖：AI-SUB-001。

### AI-SUB-004：FFmpeg 音频分段抽取

范围：

- 从媒体文件指定时间范围抽取音频。
- 输出 16k mono WAV 或 PCM。
- 支持指定音轨 ID。

验收：

- 可抽取 `start...end` 区间。
- 支持 60 秒 chunk 和 1-2 秒 overlap。
- 抽取失败时返回结构化错误。

依赖：AI-SUB-001。

### AI-SUB-005：字幕时间轴合并与 VTT/SRT 写入

范围：

- 去除 chunk overlap 重复文本。
- 合并相邻短 cue。
- 生成 WebVTT。
- 生成 SRT 导出。

验收：

- mock segments 可生成合法 VTT。
- cue 时间戳单调递增且无明显重叠。

依赖：AI-SUB-001。

### AI-SUB-006：mpv 字幕加载与 reload 节流

范围：

- 复用 `loadExternalSubFile`。
- 加载 AI 生成的 VTT。
- 更新后调用 `sub-reload`。
- reload 间隔节流。

验收：

- 首次生成足够内容后自动出现字幕轨。
- 后续更新不频繁闪烁。

依赖：AI-SUB-003、AI-SUB-005。

### AI-SUB-007：AI 字幕后台调度器

范围：

- ahead window 任务调度。
- seek 后优先生成当前播放位置之后的窗口。
- 播放器关闭、换文件、换音轨时取消任务。

验收：

- 默认维持未来 3-5 分钟字幕。
- seek 到未生成区域后优先补齐该区域。
- 取消任务不访问已关闭的 mpv core。

依赖：AI-SUB-003、AI-SUB-004、AI-SUB-005、AI-SUB-006。

### AI-SUB-008：Apple Speech 转写 adapter

范围：

- SpeechAnalyzer/SpeechTranscriber adapter。
- 语言支持检测。
- 授权状态处理。
- 句级或词级时间戳映射为内部 segment。

验收：

- macOS 26+ 上可转写音频 chunk。
- 旧系统不触发运行时崩溃。

依赖：AI-SUB-002、AI-SUB-004。

### AI-SUB-009：Apple Translation 翻译 adapter

范围：

- TranslationSession adapter。
- LanguageAvailability 检测。
- 批量翻译 cue 文本。

验收：

- 可将 transcript segments 翻译成目标语言。
- 不可用语言对给出可恢复错误。

依赖：AI-SUB-002、AI-SUB-005。

### AI-SUB-010：Apple 主路径串联

范围：

- Apple Speech + Apple Translation 串联到调度器。
- 本地能力优先选择。
- 失败时返回可降级错误。

验收：

- macOS 26+ 能完整生成并加载 AI 字幕。
- Apple 部分不可用时能提示降级到云或 whisper。

依赖：AI-SUB-007、AI-SUB-008、AI-SUB-009。

### AI-SUB-011：OpenAI 云转写与翻译 adapter

范围：

- OpenAI API Key Keychain 存储。
- 音频 chunk 上传转写。
- 文本翻译。
- 成本估算。

验收：

- 用户授权后可使用 OpenAI 生成字幕。
- 任务开始前能展示预计用量/费用范围。

依赖：AI-SUB-002、AI-SUB-004、AI-SUB-005。

### AI-SUB-012：阿里云 Paraformer 与机器翻译 adapter

范围：

- 阿里云 API Key/Secret Keychain 存储。
- Paraformer 录音文件识别。
- 阿里机器翻译。
- 成本估算。

验收：

- 用户授权后可使用阿里云生成字幕。
- 能处理异步识别任务或轮询。

依赖：AI-SUB-002、AI-SUB-004、AI-SUB-005。

### AI-SUB-013：云端隐私与授权 UX

范围：

- 第一次使用云 provider 的确认弹窗。
- 设置中 provider 说明。
- API Key 管理。
- 禁止默认自动上传。

验收：

- 云端功能未授权时不会上传音频或文本。
- 用户可撤销授权并删除 Keychain 凭据。

依赖：AI-SUB-011、AI-SUB-012。

### AI-SUB-014：whisper.cpp 模型管理

范围：

- 检测 whisper.cpp binary。
- 模型下载/导入/删除。
- 模型大小和速度说明。

验收：

- 未安装模型时 UI 有明确状态。
- 已安装模型可被 provider selection 识别。

依赖：AI-SUB-002。

### AI-SUB-015：whisper.cpp 转写 adapter

范围：

- 运行 whisper.cpp。
- 解析输出为内部 segments。
- 支持取消、进度、错误恢复。

验收：

- 可离线转写本地音频 chunk。
- 任务取消后子进程被终止。

依赖：AI-SUB-004、AI-SUB-014。

### AI-SUB-016：播放器 UI 入口

范围：

- 字幕菜单：生成 AI 字幕、停止生成、导出字幕。
- 无字幕时自动提示。
- 目标语言选择。

验收：

- 用户可以在播放器内完成全部操作。
- 已有字幕时不自动打扰。

依赖：AI-SUB-007、AI-SUB-010。

### AI-SUB-017：设置页

范围：

- 默认目标语言。
- provider 优先级。
- 云 API Key。
- 缓存大小与清理。
- whisper 模型管理入口。

验收：

- 设置持久化。
- 改 provider 后新任务按新设置运行。

依赖：AI-SUB-002、AI-SUB-003、AI-SUB-013、AI-SUB-014。

### AI-SUB-018：生成状态与错误反馈

范围：

- OSD 或侧边栏状态。
- 当前已缓存时间范围。
- provider 错误提示。
- 重试入口。

验收：

- 用户能知道字幕正在准备、已覆盖到哪里、失败原因是什么。
- 错误提示不打断播放。

依赖：AI-SUB-007、AI-SUB-016。

### AI-SUB-019：字幕导出

范围：

- 导出 VTT。
- 导出 SRT。
- 文件命名和保存位置。

验收：

- 已生成字幕可导出为独立文件。
- 导出的字幕可再次作为外部字幕加载。

依赖：AI-SUB-005、AI-SUB-016。

### AI-SUB-020：测试与样本媒体

范围：

- VTT/SRT 单测。
- 缓存键单测。
- provider selection 单测。
- seek/cancel 集成测试。
- 中英日等样本文本。

验收：

- 基础逻辑有自动化测试覆盖。
- 至少覆盖本地短视频、长视频、无音轨、已有字幕四类场景。

依赖：M1 以后持续推进。

## 推荐推进顺序

第一批只做最小可跑通闭环：

1. AI-SUB-001：核心数据模型与状态机
2. AI-SUB-002：Provider 协议与能力探测
3. AI-SUB-003：缓存键与缓存存储
4. AI-SUB-005：VTT/SRT 写入
5. AI-SUB-006：mpv 字幕加载与 reload

第二批接入真实音频：

1. AI-SUB-004：FFmpeg 音频分段抽取
2. AI-SUB-007：后台调度器

第三批打通 Apple 主路径：

1. AI-SUB-008：Apple Speech 转写
2. AI-SUB-009：Apple Translation 翻译
3. AI-SUB-010：Apple 主路径串联

第四批补产品化和云兜底：

1. AI-SUB-016：播放器 UI 入口
2. AI-SUB-018：状态与错误反馈
3. AI-SUB-011：OpenAI adapter
4. AI-SUB-012：阿里云 adapter
5. AI-SUB-013：云端隐私与授权 UX

第五批再做 whisper.cpp 与导出完善：

1. AI-SUB-014：whisper.cpp 模型管理
2. AI-SUB-015：whisper.cpp 转写 adapter
3. AI-SUB-017：设置页
4. AI-SUB-019：字幕导出
5. AI-SUB-020：测试与样本媒体
