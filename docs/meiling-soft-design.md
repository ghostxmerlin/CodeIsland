# 美玲 Mac 纯软件方案（研究 + 原型）

日期：2026-10-25　分支：aism `feat/meiling-soft`（从 `feat/meiling` 开出，本地，未提交，不推送）
依据：luna-work `docs/superpowers/specs/2026-10-24-meiling-design.md`（Tab5 方案）、`docs/meiling/p0-probe.md`

## 1. 结论

Tab5 上的听写和会议同传可以完整搬到 Mac 上，只用软件，不需要 Tab5：

| Tab5 方案 | Mac 纯软件方案 | 状态 |
|---|---|---|
| Tab5 麦克风（机身 / 耳机） | Mac 麦克风（默认输入，或按名字选） | 已实现；需要你授权麦克风 |
| 屏幕按钮 / DualKey：点按锁定、按住对讲 | 全局说话键，默认**右 ⌘**（点按锁定、按住 ≥0.3 s 对讲、组合键自动取消、Esc 取消） | 已实现 |
| Tab5 连 Gemini（transcribe-live） | Mac 直连同一个模型，同一套 setup | 已实测 |
| 键盘帧 + Scroll Lock 回执 → aism 解码 → 美玲输入法上屏 | **直接**交给美玲输入法上屏（CFMessagePort → `insertText`），不再需要键盘编码和回执 | 已实现；等你在系统设置里加一次输入法后实测 |
| Tab5 USB 声卡的麦克风（会议软件选它） | **虚拟麦克风「Meyrin Virtual Mic」**：自研 AudioServerPlugIn（libASPL），没装时回落到 BlackHole 2ch | BlackHole 路径已实测；自研驱动已编译，待安装验证 |
| Tab5 USB 声卡的扬声器（收对方声音） | **Core Audio 进程 tap**（macOS 14.2+）录系统播放的声音，排除 AISM 自己 | 已实现；需要你授权“系统音频录制” |
| Tab5 屏幕上的对方中文字幕 | Mac 上的“对方字幕”浮窗，**共享屏幕时不可见** | 已实现 |
| Mac 浮动字幕窗（我方英文） | 原样复用 | 已实现 |

输入法保留，并且是唯一的上屏通道（反目标不变：不碰剪贴板、不写辅助功能文本值、不模拟粘贴）。
Tab5 那条键盘帧通路（`MeilingCoordinator`）没有改动，两者可以同时开。

## 2. 结构

```
                    ┌──────────── AISM.app（菜单栏常驻）────────────┐
 右⌘ ──listen-only tap──▶ MeilingSoftHotkey ──edge──▶ MeilingSoftController
                    │                                  │          │
 Mac 麦克风 ──AVAudioEngine──▶ MeilingDictationEngine ─┘          │
                    │   16 kHz PCM16 ─▶ MeilingLiveSession(transcribe-live) │
                    │   inputTranscription ─▶ MeilingSoftCommitter          │
                    │        选美玲 → 等激活 → CFMessagePort 提交 → 切回     │
                    │                          │                            │
                    │                 美玲输入法.app（IMK，insertText）──▶ 光标处
                    │                                                       │
                    │   MeilingMeetingEngine ◀──────────────────────────────┘
 Mac 麦克风 ───────▶│   出去：live-translate en ─24 kHz─▶ MeilingVirtualMic ─▶ BlackHole 2ch ─▶ 会议软件的“麦克风”
 会议软件播放 ─tap─▶│   进来：live-translate zh-Hans ─转写─▶ 对方字幕窗（不进共享）
                    │   我方转写 ─▶ 美玲字幕窗（进共享）
                    └────────────────────────────────────────────────────────┘
```

代码（aism 仓库）：
- `Sources/CodeIslandCore/Meiling/`（纯逻辑，有单测）
  - `MeilingLiveProtocol.swift`：两种 setup、音频消息、服务器消息解析（和固件 `gemini_meiling_protocol.cpp` 同一线格式）；
  - `MeilingTalkGesture.swift`：点按锁定 / 按住对讲（照搬固件 `press_gesture`），加了“组合键取消”；
  - `MeilingText.swift`：去掉中文字间空格、繁转简、字幕断句（句末标点或 800 ms 无新片段）。
- `Sources/MeilingSoftKit/`（macOS 平台层，App 和 CLI 共用）
  - `MeilingLiveSession.swift`：URLSessionWebSocketTask；setup 10 s 超时；退避 1/4/16 s；持续性错误 3 次停；goAway 带续传句柄重连；连上前的音频最多存 10 s；
  - `MeilingAudio.swift`：设备枚举、重采样、麦克风、虚拟麦克风（抖动缓冲：攒 120 ms 起播，上限 1.5 s，满了丢最旧）；
  - `MeilingSystemTap.swift`：全局立体声进程 tap（排除自己）+ 私有聚合设备 + IOProc；
  - `MeilingEngines.swift`：听写引擎、会议引擎（照搬固件 `meeting.cpp` 的规则：松手补 2 s 静音再 audioStreamEnd，尾音放到 turnComplete 或最多 8 s，原声直通互斥）。
- `Sources/CodeIsland/MeilingSoft/`（App）：说话键、上屏队列、底部 HUD、控制器；菜单在 `Meiling/MeilingMenu.swift` 的“Mac Only (no Tab5)”一节。
- `Sources/MeilingSoftCLI/`：`meiling-soft` 命令行测试台（不需要 App、不需要说话，用 WAV）。

## 3. 听写

- 按下说话键：开麦，连 `gemini-3.5-transcribe-live`（SMART，词表 120 个）。会话保持，空闲 5 分钟断开；会话满 9.5 分钟在两次按键之间换新。
- 只上屏确认句（`inputTranscription`）；半句只在 HUD 灰字显示。
- 每句上屏：选中美玲输入法 → 等它在当前 App 里激活（最多 600 ms）→ 提交 → 切回你原来的输入法。逐句串行，不会交错。
- 当前位置不接受输入法（安全输入、密码框、没有光标）时，输入法回 `inactive`，什么都不打，HUD 红字提示。这比 Tab5 方案简单：不存在“编码按键漏进当前 App”的风险，因为根本没有编码按键。
- 说话键：默认右 ⌘；在设置 → Meyrin 里点 Record… 直接按键来改，可用任意单个修饰键（左右 ⌘ ⌥ ⌃ ⇧）、fn 或 F1–F20（字母键会照常打字，所以不收）。按住右 ⌘ 时再按别的键（⌘C 之类）算快捷键，这次录音直接丢掉、关会话，不会出字。tap 是 listen-only，不吞任何按键。
- HUD 是不抢焦点的面板，显示在屏幕底部，共享屏幕时不可见。

## 4. 会议同传

**用法**：戴耳机 → 设置 → Meyrin → Meeting Interpretation → Start → 会议软件里把麦克风选成 **Meyrin Virtual Mic**（没装驱动时是 BlackHole 2ch）、扬声器保持你的耳机 → 按住右 ⌘ 说中文，对方听到英语。

- 出去：只在按住（或锁定）时把麦克风送去翻译；其余时间虚拟麦克风是静音。松手后补 2 s 静音再结束（P0 实测：不补，最后半句不翻），译音放完为止。
- 原声直通（菜单 Passthrough）：你的原声直接进虚拟麦克风，不经过 Gemini；开着时说话键无效。
- 进来：系统 tap 录到会议软件播放的声音 → 降到 16 kHz → 翻成中文，只用转写做字幕，译音不播。原声照常进你的耳机（tap 不静音）。
- 字幕：我方（英文 + 中文原话，繁转简）进“Meyrin Captions”窗，共享屏幕时对方能看到；对方（中文 + 原文）进“Their Captions”窗，`sharingType = .none`，共享屏幕时看不到。
- 外放保护：默认输出是内置扬声器时拒绝开始（麦克风会把对方的声音再翻出去）。确实要外放：`defaults write com.codeisland.app meilingSoftAllowSpeaker -bool true`。
- tap 的启动会卡在系统授权弹窗上，所以在后台线程启动；20 秒没收到声音会提示检查授权。

### 4.1 虚拟麦克风：自研驱动「Meyrin Virtual Mic」（`drivers/MeyrinMic`）

- 基于 **libASPL v3.1.2**（MIT，C++17 的 AudioServerPlugIn 框架），驱动代码只有 `Driver.cpp` 一个文件。
- 一个插件里两个设备，共享驱动内部的环形缓冲，不需要 App 和驱动之间的 IPC：
  - **Meyrin Virtual Mic**（UID `MeyrinMic_UID`）：只有输入，可见。会议软件选它当麦克风；
  - **Meyrin Virtual Mic Feed**（UID `MeyrinMicFeed_UID`）：只有输出，**隐藏**（不出现在任何设备菜单里）。AISM 按 UID 打开它，把译音放进去。
- 48 kHz 单声道 Float32，两个设备用同一个主机时钟，不需要重采样。
- 环形缓冲约 1.37 s。一个写、一个读：写方只动写指针；读方只动读指针，落后超过 100 ms 就跳到只落后 20 ms，延迟不会越积越多；攒够 20 ms 才开始出声（两边 IO 块大小不同，免得反复欠载出咔哒声），欠载后重新攒。
- AISM 默认打开“送音”设备；没装驱动时自动回落到 BlackHole 2ch，HUD 会提示会议软件该选哪个麦克风。
- 构建：`drivers/MeyrinMic/build.sh`（CMake 自动拉 libASPL，临时签名）。
- 安装：`sudo drivers/MeyrinMic/install.sh`（复制到 `/Library/Audio/Plug-Ins/HAL` 并重启 coreaudiod，所有声音会断一两秒）；卸载：`sudo drivers/MeyrinMic/install.sh -u`。

## 5. 实测（2026-10-25，用 `say` 生成的语音，不是真人）

| 项目 | 结果 |
|---|---|
| 听写，中文 9.1 s，带词表 | setupComplete 约 1.1 s；松手后 **0.6 s** 出确认句；“iTerm”认对，“Mac 端”被 TTS 口音认成“MCU 端” |
| 同传出去（中→英），进 BlackHole | 两条会话约 1.1 s 连上；译文字幕正确；BlackHole 实际拉走 **5.9 s 有声译音**，峰值 0.80 |
| 同传进来（英→中），WAV 喂入 | 开始后约 4 s 出第一句“我们下周能寄出样品吗？”，第二句“我们需要先确认地址。另外，关于价格，我们周一再谈。” |
| 系统音频 tap | 代码跑到 `AudioDeviceStart`，卡在系统授权上（我这个 shell 的宿主没有这个权限）。要在 AISM 里由你授权后验证 |
| 美玲输入法上屏 | 已安装并注册；`TISSelectInputSource` 返回 -50：macOS 26 上第三方输入法要你在系统设置里手动添加一次，命令行启用不生效 |
| 单测 | `swift test --filter "MeilingSoftCoreTests|MeilingFrameAssemblerTests"`：25 个通过（协议解析用 P0 录下的真实服务器消息） |

## 6. 权限清单（都是第一次用时）

1. **系统设置 → 键盘 → 文字输入 → 编辑 → + → 简体中文 → 美玲**（一次；平时不用选它）。
2. **麦克风**：AISM（开启 Mac 听写时会弹窗）。
3. **输入监控**：AISM（说话键）。AISM 是临时签名，每次重新编译后系统可能要求重新授权。
4. **屏幕与系统音频录制 → 仅系统音频**：AISM（第一次开始会议同传时弹窗）。
5. 会议软件里选 BlackHole 2ch 当麦克风；Zoom 建议打开“原始声音”，否则降噪可能削掉合成语音。

## 7. 已知限制 / 风险

- tap 录的是**全部**系统声音（排除 AISM），会议中放音乐也会被翻译。以后可以改成只 tap 指定 App（`CATapDescription(stereoMixdownOfProcesses:)`，菜单里选会议软件）。
- 会议中途切换输出设备（比如连上 AirPods）后 tap 的聚合设备不会跟着换，要重开会议同传。
- 蓝牙耳机：Mac 一开麦克风，AirPods 会切到通话模式（音质变差）。建议有线耳机或用 Mac 内置麦。
- 临时签名：每次重编译 TCC 授权可能失效（这也是现有 AISM 的情况）。长期可以做一个自签名证书让签名身份固定。
- API key 放在 `~/Library/Application Support/AISM/meiling.env`（0600，从 luna-work/.env 复制，菜单可改），没放钥匙串：临时签名的 App 每次重编译都会弹钥匙串授权。
- 输入法切换延迟、各 App（Codex、iTerm、Sublime、ChatGPT、Chrome、VS Code）兼容性还没测，测试清单沿用 `luna-work docs/meiling/p0-mac-results.md` 的 T5 表。

## 8. 裁定（我做的决定）

1. 说话键默认右 ⌘，在设置 → Meyrin 里按键录制（WhisperPad 已弃用，不再检查与它的快捷键冲突）。
2. 组合键 = 取消并丢弃，靠关会话保证不会迟到一句确认句再上屏。
3. 逐句上屏，每句选入 → 提交 → 切回；不在整段说话期间一直停在美玲输入法上（否则你中途打字会变成英文直出）。
4. 会议中麦克风一直开着（零延迟起说），只在按住时把声音送出去。
5. 对方字幕窗不进屏幕共享；我方字幕窗进。
6. 外放默认拒绝开始会议同传（照固件“没插耳机不让开始”）。
7. key 放 0600 文件而不是钥匙串（理由见 §7）。
8. 修了 `feat/meiling` 上安装器的 bug：只启用了输入模式、没启用输入法本身，导致输入法永远不出现在“已启用”里。

**独立审查（2026-10-25）后已修**：
- 取消后的确认句仍可能上屏：确认句现在带着产生它的会话，会话已被取消就丢掉；上屏队列可清空；
- 每个会话的 URLSession 泄漏（delegate 强引用）：关闭时 invalidate；
- 会议停止时字幕拼接有数据竞争：加锁，停止后不再回调；
- tap 被系统临时禁用期间松开说话键会卡在对讲：恢复时按真实键位补一次松开；
- 上屏队列连续两句时可能把第二句写给正要失效的输入法：切回后等 80 ms 再处理下一句；选输入法失败时也切回；
- 麦克风启动失败时会话会一直重连：安排空闲关闭；
- 会议启动中途关闭 / 停止会被忽略：启动完成时发现已取消就立刻停掉；
- 虚拟麦克风重复 start 会挂两个音源节点：只挂一次。

## 9. 回来后的验证步骤

1. 系统设置里添加“Meyrin”输入法（§6 第 1 条），并允许 AISM 的麦克风弹窗。
2. 打开 TextEdit，光标放进去，按住右 ⌘ 说一句中英混合的话，松手：HUD 先灰字后绿字，文字出现在光标处，输入法切回拼音。
3. 依次在 iTerm、Codex、Sublime、ChatGPT、Chrome、VS Code 里各试一次；iTerm 打开“安全键盘输入”时应该什么都不打、HUD 提示。
4. 戴耳机，设置 → Meyrin → Meeting Interpretation → Start，允许系统音频录制；用 QuickTime“新建音频录制”选“Meyrin Virtual Mic”，按住右 ⌘ 说中文，录到的是英语。
5. 浏览器里放一段英文视频：“Their Captions”窗出中文。
6. 日志：`~/Library/Logs/AISM/meiling.log`（只记阶段和耗时，不记文字内容）。

CLI 测试台（不需要 App）：

```
cd ~/tab5/starlight && swift build --product meiling-soft
.build/debug/meiling-soft devices
.build/debug/meiling-soft dictate --wav zh16k.wav --vocab ~/Library/Application\ Support/AISM/meiling-terms.json
.build/debug/meiling-soft out --wav zh16k.wav      # 中文 → 英语进 BlackHole，报告设备拉走多少有声音频
.build/debug/meiling-soft in --wav en16k.wav       # 英文 → 中文字幕
.build/debug/meiling-soft in --seconds 15          # 系统音频 tap（需要授权）
```

## 10. 界面语言（2026-10-25 负责人要求）

美玲项目里用户看得到的文字全部改成英语，英文名用角色官方名 **Meyrin**（Meyrin Hawke）。代码里的 ID 和类名（`com.aism.inputmethod.Meiling`、`MeyrinMic_UID`、`Meiling*`）不变。

- AISM 设置窗口侧边栏 “Meyrin” 页（菜单栏子菜单同内容，但 AISM 菜单栏图标默认不显示）：Mac Dictation / Start Meeting Interpretation / Passthrough / Talk Key / Set Gemini API Key… / Show Their Captions 等；HUD 提示、错误、字幕窗标题、权限弹窗说明都是英文。
- 输入法显示名 “Meyrin”（`InfoPlist.strings` 给输入法本身和它的模式都起了名）。
- 虚拟麦克风 “Meyrin Virtual Mic”，隐藏送音设备 “Meyrin Virtual Mic Feed”（不叫 “Meyrin Microphone”，免得和 Tab5 的 USB 麦克风重名）。
- Tab5 美玲桌面和会议页、固件错误文字、USB 描述符（“X10A Meyrin”、“Meyrin Microphone” 等）都改成英文。
- 转写和翻译的内容不变：中文照样是中文。

## 11. 听写历史（2026-10-25）

每一句定稿的听写（Mac 和 Tab5 两条路）都记进 `~/Library/Application Support/AISM/dictation-history.jsonl`（仅本人可读，保留最近 1000 句），带结果：已上屏 / 未上屏（原因）/ 已取消 / 未确认。没打进去的句子不用重说：设置 → Meyrin → Dictation History 显示最近 5 句，“Show All…” 打开历史窗口（搜索、逐句 Copy、Copy Not Typed 一次复制所有没打进去的、Clear…）。上屏失败时底部提示会写明已存进历史。最快的入口：听写时屏幕底部那条提示的右上角有 History 按钮（鼠标停在提示上时它不会自动消失），Tab5 的字幕窗右上角也有。日志 `meiling.log` 仍然不记文字。

## 12. 会议同传的按键与字幕（2026-10-25 负责人决定）

- 会议同传时说话键**只能按住说**，松手就停（听写仍是点按锁定 / 按住说话）。原因：一次点按锁定后麦克风开了 3 分多钟，把旁边视频和别人的话都翻译了。
- 字幕等整句：译文出现句末标点，或 1.5 秒没有新片段才成一行（原来 0.8 秒，行太碎）。对方听到的译音不受影响。Tab5 固件仍是 0.8 秒。

## 13. 修正学习、词表大小、松键补录（2026-10-25）

- **Gemini 接口不收发音**：`gemini-3.5-transcribe-live` 只有 `customVocabulary`（最多 1000，官方建议约 100）、`languageCodes`、`mode`；没有音标、权重、上下文提示。所以“读音 → 词”靠负责人的修正学：历史窗口里点 Edit 改对，AISM 比较前后，找出被听错的词（拉丁词取整词；中文至少两个字，不靠“的了到把”这类字扩展；改了四成以上算重写，不学），存进 `corrections.json`（仅本人可读）。
- **改一次就生效**（负责人选）：之后每一句（Mac 和 Tab5）打出去前先替换（长的先换；已经是正确词的部分不动）；改对的词排在词表最前面。设置 → Meyrin → Corrections 可以逐条关掉或删除。
- **词表约 150 条**（负责人选）：生效的 `meiling-terms.json` 153 条（项目名、型号、AI 工具、听错过的领域词），其余 488 条在 `vocab/meiling-terms-reserve.json`，不生效；AISM 最多取 150 条（修正词优先）。
- **松键补录 0.5 秒**：松开说话键后麦克风再录 0.5 秒才结束（听写和会议同传都是），最后一个字不再被截断；0.5 秒内再按算同一段。

## 14. 软件模式与硬件模式分开（2026-10-25 负责人要求）

“不要和将来的硬件模式搞混”：
- `Sources/CodeIsland/Meiling/`：**Tab5 硬件模式**（按键帧解码、LED 回执、Tab5 字幕窗、菜单栏 “Meyrin (Tab5)” 菜单）。不碰软件模式的历史、修正、词表。
- `Sources/CodeIsland/MeilingSoft/`：**Mac 软件模式**（说话键、听写、会议同传、自己的两个字幕窗、提示条、设置 → Meyrin 页、历史、修正）。
- `Sources/CodeIsland/MeilingShared/`：两者真正共用的：Meyrin 输入法的客户端和“已激活”端口（一个进程只能有一个）、输入法切换、安装、日志（2 MB 轮换）。
- 审查建议的“两条路合成一个打字流程”不做。
