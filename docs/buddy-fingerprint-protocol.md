# Buddy 指纹协议（一期）：给 CodeIsland 的实现说明

日期：2026-10-22。适用固件：`~/atom` 分支 `buddy-led`（aism，M5 Atom Voice + Unit Fingerprint2）。
本文所有字节示例都是真机上实际收发的。设计背景见 `~/atom/docs/superpowers/specs/2026-10-22-buddy-fingerprint-design.md`（测试工具在 `~/atom/aism/tools/fpctl.py`）。

## 1. 这份文档让 CodeIsland 做什么

aism 现在多了一个指纹模块，CodeIsland 要实现三件事：

1. **指纹管理界面**：录入、列出、比对、删除。
2. **锁屏指纹解锁**：复刻 `~/exia` 的 UnlockProbe。Mac 锁屏后发质询，用户在 Atom 上按手指，Atom 回一个 HMAC 标签，
   CodeIsland 校验通过后从钥匙串取登录密码并输入。
3. **审批提示**：批准权限请求现在必须在 Atom 上按指纹（按键只能拒绝）。上行协议**没变**，只需要在界面上提示用户。

开工前先改 BLE 发送队列（2.1 节）：不改的话，指纹帧会排队、甚至被丢掉，上面三件事都会时灵时不灵。

## 2. 通道

- 走现有的 buddy 服务：Service `0xBEEF`，写特征 `0000beef-0001-1000-8000-00805f9b34fb`（write / write without
  response），通知特征 `0000beef-0002-1000-8000-00805f9b34fb`。
- 先完成现有的应用层配对（`E0 + hostId` → 设备回 `E0`）。**未配对的连接发来的指纹帧一律丢弃。**
- 指纹帧的**第一个字节固定是 `0xD0`**，上下行都一样。其他首字节的含义不变。
- **每帧都不超过 20 字节**，不用协商 MTU。
- 兼容性：
  - 老固件会忽略 `0xD0` 帧，不回任何东西。CodeIsland 可以发一次 `STATUS`，**5 秒**内没有回执就再试一次，还是没有，就当这台设备不支持指纹。
    （不要等得太短：固件正在删除全部指纹时，最长要约 5 s 才处理下一个请求。）
  - 现在的 `BuddyUplinkEvent(payload:)` 遇到首字节 `0xD0` 会返回 nil，所以要加一个新的 case 来解析指纹帧。

### 2.1 发送队列：指纹帧不能排队，更不能丢（必须改）

**现状**（`Sources/CodeIsland/ESP32BridgeManager.swift` 的 `BuddyWriteQueue`）：
- 容量 64 帧，`popFirst()` 严格先进先出。优先级只决定**满了丢谁**，不决定谁先发。
- `ESP32StatePublisher.flush()` 每次状态变化、每次 5 s 心跳都要发 15–25 帧（状态、工作区、预览、模型、统计、工具历史……）。
  agent 忙的时候，队列几乎一直是满的。

**实测**（2026-10-22，用 `log stream` 抓 CodeIsland 的日志，对照 Atom 串口日志）：

| Atom 的 BLE 连接参数 | 钩子事件 → Atom 收到状态 | `Dropped … under write backpressure` |
|---|---|---|
| 150 ms，latency 4（旧固件） | 0.4–7 s，多数 1–4 s；一次审批晚了 5.7 s | 约 19,000 帧/分钟 |
| 15–30 ms，latency 0（现在的固件，commit `fb4fad7`） | 多数 0.01–0.3 s | 约 300 帧/分钟 |

固件这边已经改快了，但队列还是会满、还是会丢帧。这对状态灯只是晚一点；对指纹帧就是功能故障：
- `UNLOCK_CHALLENGE` 的两帧排在一堆预览后面，解锁要等好几秒；如果被丢掉一帧，这一轮就永远等不到手指。
- `CANCEL` 被丢，Atom 会一直等手指，按键也一直不能用。
- `STATUS` 被丢，会被误判成"老固件、不支持指纹"（见上面 5 s 重试的规则）。

**要求**：
1. **`0xD0` 帧永远不丢。** 用 `.control` 优先级还不够，因为队列里全是 `.control` 时照样会丢最旧的那一帧。
   简单的做法是给 `0xD0` 单独开一个不设上限的小队列（一期同一时刻最多只有一个未完成的请求，加上 `CANCEL`，不会多）。
2. **`0xD0` 帧先发。** 每次 `drainPendingWrites` 先把指纹队列发完，再发普通队列。指纹帧之间保持先后顺序：
   `UNLOCK_CHALLENGE` 的 offset 0 必须在 offset 16 之前到达。
3. **（建议）普通队列也按优先级出队**，同优先级内先进先出。这样状态帧（`.primary`）不会被预览和工具历史挡住，状态灯也就跟着及时了。
4. **（建议）合并重复帧**：入队时，如果队列里已经有一帧"同一种、同一个位置"的旧数据，就用新的替换掉旧的，不要再追加一帧。
   这样一次心跳不会再把队列塞满。"同一种"按首字节判断：状态帧、`0xFC` 工作区、`0xF9` 模型、`0xFA` 统计、`0xF8` 子代理、`0xF6` 时间；
   "同一个位置"指的是 `0xFB` 预览、`0xF5` 工具历史还要再看 index。`0xF7` 事件和 `0xD0` 指纹帧**不能**合并。

## 3. 帧格式

```
请求（Mac → Atom）：D0 op reqId payload[0..17]
回执（Atom → Mac）：D0 (op|0x80) reqId result payload[0..16]
事件（Atom → Mac）：D0 70 reqId result type data[0..15]
```

- `reqId`：1–255，由 Mac 分配，每个请求加 1，到 255 后回到 1；0 无效。
- 同一时刻**只能有一个未完成的请求**，`CANCEL` 除外（随时可以发）。
- 事件里的 `reqId` 等于发起这次操作的那个请求的 id（录入、比对、解锁）。
- 格式错误、长度不对或 op 未知 → 回 `Invalid`。`reqId` 为 0、op ≥ 0x80 的帧解析不了，**不回任何东西**。
- 多字节整数都是**小端**（slot 是 `LE16`）。

## 4. op

| op | 名字 | 请求 payload | 成功回执 payload | 说明 |
|---|---|---|---|---|
| `01` | STATUS | 空 | `ver, present, count, hasAttest, activeOp`（各 1 字节） | `ver`=1；`count` 为 0xFF 表示还不知道；`hasAttest` 一期恒为 1；`activeOp`：0 空闲 / 1 录入 / 2 比对 / 3 解锁 / 4 审批等指纹 |
| `21` | ENROLL_BEGIN | `slot LE16`；`FF FF` = 自动选第一个空槽 | 空（已开始） | 进度和结果走事件 type 1 |
| `22` | CANCEL | 空 | 空 | 取消正在进行的录入、比对或解锁；被取消的操作会再发一条 `Cancelled` 事件 |
| `23` | FP_LIST | 空 | 13 字节位图 | byte `i/8` 的 bit `i%8` = 槽 `i`（0–99）已录入 |
| `24` | FP_VERIFY | 空 | 空（已开始） | 1:N 比对一次，结果走事件 type 4。**永远不会解锁或批准** |
| `25` | FP_DELETE | `slot LE16`；`FF FF` = 全部 | 空（已删除） | 一期没有设备端确认 |
| `42` | ATTEST_STATUS | 空 | `hasAttest(1)=1, hasFinger(1), SHA-256(K)[0:8]` | 用来核对两端的 K 一致：一期应为 `d9dfb16ead4ef7db` |
| `43` | UNLOCK_CHALLENGE | `offset(1) + 16 字节`，分两帧：offset `00` 和 `10` | 第一帧回 `Ok`+`10`（已收字节数）；第二帧回 `Ok`（空，表示已开始等手指） | 两帧必须用同一个 `reqId`、按顺序发；换 id、乱序或断线都会作废，从 offset 0 重新发即可。第一帧只是收数据，**总是**回 `Ok`+`10`；`Busy`、`NoBinding`、`NoSensor` 这些拒绝都在第二帧的回执里 |
| `40`/`41` | ATTEST_SET / DELETE | — | 一期回 `Invalid` | 二期用来下发每台设备各自的 K |

**回执要等多久**：大多数请求在 0.5 s 内就有回执。模块闲置后的第一条命令要多等约 0.3 s，`FP_DELETE FF FF` 最长约 5 s，
建议回执超时设成 **8 s**。

## 5. 事件

| type | 什么时候 | result 和 data |
|---|---|---|
| 1 录入进度 | 每次阶段变化 | `Ok` + `stage, sample, slot LE16`。失败（终结）：`Duplicate` / `SensorError` / `Timeout` / `Cancelled` |
| 2 解锁 | 比对的结果 | 成功（终结）：`Ok` + 14 字节 tag。按错手指：`NoMatch`，没有 data，**不终结**，Atom 会等手指抬起后继续等。失败（终结）：`Cancelled` / `SensorError` |
| 4 比对 | 比对一次的结果 | `Ok` + `slot LE16`；或者 `NoMatch` / `Timeout` / `SensorError` / `Cancelled`，slot = `FF FF` |

**录入的 stage**（终结条件是 `stage == 5`）：

| stage | 含义 | 界面上可以显示 |
|---|---|---|
| 1 | 等手指放上来（`sample` = 已完成的次数） | "请放上手指（第 N/6 次）" |
| 3 | 这一次已采到，处理中（沿用 exia 的名字是"调整角度"，实际**每次采集都会出现**） | "处理中…" |
| 2 | 这一次采好了，请抬起 | "请抬起手指"，Atom 同时短闪绿色 |
| 4 | 保存中（最后会出现 1–2 次） | "保存中…" |
| 5 | 完成 | "录入完成，槽位 X" |

真机上每次按压的顺序是 `1 → 3 → 2`，共 6 次，最后是 `4 → 5`。

**时间限制**：
- 录入整体最长 60 s。模块每次按压大约只等 **8 s**，超时就以 `Timeout` 结束。所以界面上点"录入"之后，要提示用户马上按。
- 比对同样大约等 8 s，超时回 `Timeout`。
- 解锁**没有时长上限**：模块 8 s 超时后 Atom 会自己重新开始等，一直到比对成功、Mac 发 `CANCEL`、发来新的质询，或者断线。
- **模块被拔掉**：模块不会报错，只是不再回包。Atom 在等手指时如果 **12 s** 收不到任何包，就判定模块不在：
  进行中的录入、比对、解锁以 `SensorError` 结束，之后 `STATUS` 的 `present` 变成 0。插回去后，下一个请求或下一次红灯时会重新探测。

## 6. 结果码（十进制）

| 码 | 名字 | 含义 |
|---|---|---|
| 0 | Ok | 成功 |
| 1 | WaitConfirm | 二期：等设备上确认（一期不会出现） |
| 2 | Invalid | 请求无效（长度、slot 越界、槽已占用、分块错误、op 未知或保留） |
| 3 | Busy | 已经有录入、比对或解锁在进行 |
| 6 | NoSensor | 没有检测到指纹模块 |
| 7 | SensorError | 模块出错 |
| 8 | Timeout | 超时（模块等手指超时，或录入超过 60 s） |
| 9 | Cancelled | 被取消（`CANCEL`、新的质询替换了旧的） |
| 14 | NoAttest | 二期：没有 K（一期不会出现） |
| 15 | NoMatch | 没有匹配到已录入的指纹 |
| 16 | NoBinding | 一个指纹都没录（不能比对或解锁） |
| 17 | Duplicate | 录入时，这根手指已经录过了 |
| 18 | Full | 100 个槽都满了 |

**互斥规则**：录入、比对、解锁、删除、列出同一时刻只能有一个。正在录入、比对或解锁时，再发录入、比对、删除、列出会回 `Busy`
（正在录入或比对时发解锁质询，也回 `Busy`）。
`STATUS`、`ATTEST_STATUS`、`CANCEL` 随时都能发。正在解锁时发新的 `UNLOCK_CHALLENGE`，会**替换**旧的轮次：
先给旧的 reqId 发 `Cancelled` 事件，再给新的回 `Ok`。

## 7. 时序示例（真机实测）

配对（每次连接后）：
```
-> e0 b6 99 11 45 af 92        配对请求，hostId = b69911 45af92
<- e0                          已接受（记住的 Mac）
```

STATUS：
```
-> d0 01 01
<- d0 81 01 00 01 01 05 01 00  ver=1 present=1 count=5 hasAttest=1 activeOp=0
```

列出：
```
-> d0 23 01
<- d0 a3 01 00 1f 00 00 00 00 00 00 00 00 00 00 00 00     槽 0–4 已录入
```

录入（自动选槽，分到槽 5）：
```
-> d0 21 01 ff ff
<- d0 a1 01 00                         已开始
<- d0 70 01 00 01 01 00 05 00          stage 1，第 0 次，槽 5
<- d0 70 01 00 01 01 01 05 00          stage 1，第 1 次
<- d0 70 01 00 01 03 01 05 00          stage 3
<- d0 70 01 00 01 02 01 05 00          stage 2（抬起）
   ……共 6 次……
<- d0 70 01 00 01 04 06 05 00          保存中
<- d0 70 01 00 01 05 06 05 00          完成，槽 5
```
重复手指的结束帧：`d0 70 01 11 01 00 06 05 00`（result `0x11` = Duplicate）。

比对：
```
-> d0 24 01
<- d0 a4 01 00
<- d0 70 01 00 04 05 00                匹配槽位 5
```

删除：
```
-> d0 25 01 05 00
<- d0 a5 01 00
```

解锁（先按错再按对）：
```
-> d0 43 01 00 55 eb 48 43 d3 59 8a 39 d1 41 d7 d1 f5 e3 25 6f    nonce 前 16 字节
<- d0 c3 01 00 10                                                已收 16 字节
-> d0 43 01 10 94 74 b6 0f c0 94 92 01 0a 40 b7 80 dd 66 14 45    nonce 后 16 字节
<- d0 c3 01 00                                                   开始等手指
<- d0 70 01 0f 02                                                NoMatch，继续等
<- d0 70 01 00 02 e9 e2 da 62 84 8e ac 88 2e 7b bd 90 ee be      Ok + tag
```
校验：`HMAC-SHA256(K, "EXIA-UNLOCK-v1\0" ‖ nonce)` 的前 14 字节 = `e9e2da62848eac882e7bbd90eebe`，和上面一致。

取消：
```
-> d0 22 02
<- d0 a2 02 00                         CANCEL 的回执
<- d0 70 01 09 02                      被取消的解锁轮次（reqId 1）结束：Cancelled
```

## 8. 解锁：Mac 端要做的事

**一期的 K（固定常量，两端写死）**：
- K = ASCII 字符串 `aism-fingerprint-phase1-test-key`，正好 32 字节。
- `SHA-256(K)` 的前 8 字节 = `d9dfb16ead4ef7db`。

**一轮解锁的流程**：
1. 检测到锁屏，而且 Atom 已连接、已配对。可以先发一次 `ATTEST_STATUS`，确认 `hasFinger=1`、K 的指纹一致。
2. 生成 32 字节随机 nonce，**每轮都用新的**，用 `UNLOCK_CHALLENGE` 分两帧发出。
3. 等事件 type 2：
   - `NoMatch`：可以提示"指纹不匹配"，然后继续等。
   - `Ok`：用本地的 K 计算 tag，用**常数时间**比较。一致 → 进入输入密码的流程；不一致 → 这一轮失败。
   - 其他结果：这一轮失败。
4. 用户用别的方式解锁了（密码、Touch ID、Apple Watch），或者 Mac 要睡眠了，要发 `CANCEL`，否则 Atom 会一直等手指。

**fail-closed**：没连上、配对失败、超时、`NoMatch`、tag 校验失败、锁屏状态不对，这些情况都**一个字符都不输入**，退回让用户手动输密码。
一个 nonce 只用一次；收到 tag 后，这一轮就结束了。

### 8.1 登录部分：照搬 exia 的做法

下面整理自 exia `Sources/main.swift`（`PasswordStore`、`LockScreen`、`AppDelegate.tick()`）和 `ProbeGate.swift`，
在 macOS 26.5.2 arm64 上真机验证过一次完整的锁屏解锁。

**一次性设置（用户在 CodeIsland 设置里做）**
1. **保存登录密码**：用户在安全输入框（`NSSecureTextField`）里输入当前账户的登录密码，存进钥匙串：
   - `kSecClassGenericPassword`，`kSecAttrService` = CodeIsland 自己的条目名（exia 用的是 `io.exia.UnlockProbe.password`），
     `kSecAttrAccount` = `NSUserName()`，加一个能看懂的 `kSecAttrLabel`。
   - 先 `SecItemUpdate`，返回 `errSecItemNotFound` 再 `SecItemAdd`。保存后清空输入框，并把 `Data` 清零（`resetBytes`）。
   - 保存时**不校验**密码对不对，界面上要说明"保存不代表密码正确"。
   - 用传统的登录钥匙串，不设置宽泛的共享 ACL，不读别的应用存的密码。
2. **辅助功能授权**：用 `AXIsProcessTrusted()` 检查；没有授权就调用 `AXIsProcessTrustedWithOptions`（带 prompt 选项）引导用户去
   系统设置 → 隐私与安全性 → 辅助功能里打开。注意：临时签名的构建每次重新编译后，可能要重新授权，钥匙串条目也可能要重新保存。
3. **一期不需要配置 K**：K 是固定常量，直接写在代码里（exia 是生成随机 K、存在 `io.exia.UnlockProbe.attest`，再下发给设备，二期再这么做）。
   连上后发一次 `ATTEST_STATUS`，核对 `SHA-256(K)[0:8]` 是 `d9dfb16ead4ef7db`、`hasFinger=1`。

**判断锁屏**（exia 每 0.25 s 查一次）
- 读 `CGSessionCopyCurrentDictionary()`：
  - 有 `CGSSessionScreenIsLocked` 或 `ScreenIsLocked`，就以它的值为准；
  - 否则 `kCGSessionOnConsoleKey == true` 且 `kCGSessionLoginDoneKey == true`，算"未锁定"；
  - 都没有就是"未知"。**"未知"按不能解锁处理**，这一轮停止。
- 这些字段依赖系统行为，换 macOS 版本要实测。

**什么时候发质询**
- exia 的"自动模式"：每次锁屏（或唤醒）只发起一轮。发起前要满足这些条件：有辅助功能授权、钥匙串里有密码、设备已连接、
  `ATTEST_STATUS` 正常。条件不满足时**不要**把"本次已发起"记下来，下一次检查时再试（刚重连时 `ATTEST_STATUS` 的回执可能还没到）。
- 解锁后（读到"未锁定"）清掉"本次已发起"，下次锁屏才能再发起。
- **设备重连了**：旧连接上正在进行的那一轮已经作废，要结束它，允许用新的 nonce 重新发起。
- exia 的门（`ProbeGate`）规则：发起后先看到"已锁定"才发质询；如果中途看到"未锁定"（用户用别的方式解锁了），
  这一轮停止；锁屏状态"未知"也停止。exia 有 90 s 的总时限；aism 这边解锁不限时，CodeIsland 可以不设时限，
  但只要这一轮停止，就要给 Atom 发 `CANCEL`。

**校验通过后输入密码**（exia `LockScreen.target()` / `enter()`）
1. 从钥匙串读密码：`SecItemCopyMatching`，带一个 `interactionNotAllowed = true` 的 `LAContext`（绝不弹窗）。
   用完立刻清零。读取失败（钥匙串锁着、没有权限）就停止，**不能**替用户去解锁钥匙串。
2. 输入前检查目标，**每一段字符之前和回车之前都要重新检查一次**：
   - 锁屏状态必须是"已锁定"（`true`）；
   - 前台应用的 bundle id 是 `com.apple.loginwindow`，可执行文件路径是
     `/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow`；
   - 用 `SecCodeCopyGuestWithAttributes`（按 pid）加 `SecCodeCheckValidity` 校验签名，要求是
     `anchor apple and identifier "com.apple.loginwindow"`；
   - `CGWindowListCopyWindowInfo` 里能找到这个 pid 的一个可见窗口，宽和高都大于 100。显示器关着的时候没有这个窗口，
     要提示用户用实体键唤醒屏幕。
   - 两次检查之间 pid 变了，就停止。
3. 输入：
   - 密码转成 UTF-16，不能为空，也不能含 `\n`/`\r`；
   - 每 20 个 UTF-16 单元一段，用 `CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 0, …)`
     加 `keyboardSetUnicodeString` 生成按下和抬起两个事件，`flags = []`，`post(tap: .cghidEventTap)`；
   - 最后发回车：`virtualKey: 36`，按下加抬起；
   - 输入完把 UTF-16 数组清零。
4. 提交后 **8 s** 内读到"未锁定"，就算成功；否则这一轮停止，**不重试**，让用户手动输入密码。一轮只输入一次。

**注意事项**
- 密码不能出现在命令行参数、剪贴板或日志里。Swift 的 `String` 和框架内部可能还有短暂的内存副本，这一点没法完全保证擦除。
- 锁屏密码框里已经有字符、输入法状态、系统安全输入，都可能让这一轮失败。CGEvent 是按焦点分发的，上面的检查只能缩小、不能完全消除
  焦点竞争。
- 只覆盖已登录用户的锁屏；不覆盖注销后登录、重启后的首次登录和 FileVault 启动解密。
- 不要自动锁屏，不要修改 PAM 或系统认证规则。

### 8.2 和 exia 不一样的地方（不要照抄）

| | exia（StickS3） | aism（本协议） |
|---|---|---|
| 收到 `NoMatch` | 这一轮结束（`gate.fail()`），要等 BtnA 或屏幕唤醒才重新发起 | **不结束**，Atom 等手指抬起后继续等。Mac 端只更新提示，**不要**结束这一轮，也不要换 nonce |
| 设备主动请求解锁 | 有：EVENT type 3（按 Stick 的 BtnA） | **没有**。Atom 的按键在红灯时是拒绝，平时是聚焦终端，不会发起解锁 |
| K | 随机生成，钥匙串保存，经 `ATTEST_SET` 下发，需要设备上按 B 确认 | 一期固定常量，不下发 |
| 帧格式 | `50 01 op id …`，事件 `50 01 70 id result type …` | `D0 op id …`，事件 `D0 70 id result type …`。tag 同样在 type 后面，算法相同（14 字节） |
| 设备端超时 | 一轮约 8 s 就结束（exia 记录的开放问题） | 没有总时限，模块 8 s 超时后自动重新等 |

**参考实现**（`~/exia/Sources`）：
- `StickLink.swift`：BLE 连接
- `Attestation.swift`：HMAC 校验
- `ProbeGate.swift`：每轮只放行一次
- `main.swift`：锁屏检测、钥匙串、CGEvent 输入，以及输入前对 loginwindow 的检查

exia 当时踩过的坑：
- 连接要有超时（15 s），超时就取消，重新扫描。
- 蓝牙关掉再打开后，外设会失效，但不会回调 `didDisconnect`。所以每次 `poweredOn` 都要丢掉旧外设、重新扫描。
- 不要同时开两轮质询：比如重连后自动开了一轮，又有别的触发再开一轮。第一轮的回答会拿去和第二轮的 nonce 比对，结果失败。
  （aism 这边新质询会替换旧的，旧 reqId 会收到 `Cancelled`，Mac 端也要按 reqId 对应好。）
- 输入密码前，再确认一次锁屏窗口在前台；只输入一轮，失败后不自动重试。

## 9. 审批

- 上行协议**没变**：批准还是单字节 `F0`，拒绝还是 `F1`。区别是 `F0` 现在**只会由指纹比对触发**，按键只会发 `F1`。
- 界面建议：buddy 处于"等待批准"时，如果 `STATUS` 显示 `present=1` 且 `count>0`，就提示"在 Atom 上按指纹批准"；
  否则提示"请在 Mac 上批准"（模块不在或没有录指纹时，Atom 上没办法批准）。模块在等待中被拔掉后，最多 12 s `present` 才会变成 0，
  所以进入"等待批准"时重新查一次 `STATUS` 比较准。
- 设备端还有这些规则（CodeIsland 不用实现，了解就行）：
  - 每次批准都要一次新的按压：手指一直按着，不会连着批准队列里的下一个请求；请求出现时手指已经搭在传感器上，也要先拿开再按。
  - 锁屏解锁优先：收到解锁质询时，审批等指纹会自动停止，转去等解锁的手指。
  - 解锁、比对、录入进行中，按键什么都不发。
- `F0` 不带会话 id，作用于 CodeIsland 队列最前面的那个请求（和以前一样）。

## 10. 一期的安全边界（一定要读）

- **一期解锁没有安全性可言**：K 是公开的固定常量，BLE 链路也不加密。任何知道 K、又能在用户锁屏时冒充 aism 连上 Mac 的人，都能伪造出合法的 tag。
  一期只用来把流程跑通，**不要在需要保护的机器上默认打开**。
- 指纹数据（模板）不会离开模块；登录密码只存在 Mac 的钥匙串里，永远不经过 BLE。
- 录入和删除一期都没有设备端确认，只要求连接已经完成应用层配对。

**二期会有这些变化**（CodeIsland 先留好位置）：
- BLE 链路加密和绑定（LE Secure Connections）。
- 每台设备各自的 K：用 `ATTEST_SET`（`40`）下发，`ATTEST_DELETE`（`41`）删除，`hasAttest` 可能是 0，解锁可能回 `NoAttest`（14）。
- 录入、删除、写入 K 时可能先回 `WaitConfirm`（1），用户在设备上确认后，再回最终结果。看到 `WaitConfirm` 不能当成成功。
- 解锁轮次可能加上按错次数和时长的上限。
