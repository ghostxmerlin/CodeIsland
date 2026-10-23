# Borrowing immurok's macOS auth stack into AISM — research + adoption design

Date: 2026-10-23. Status: decision-support document, no code changed.

Sources read (all line numbers below refer to these exact trees):

- **AISM** — `/Users/ghostxmerlin/tab5/starlight`, branch `feat/buddy-fingerprint`, HEAD `f71e8b0` (one commit past `e0a2423`).
- **immurok** — `github.com/immurok/app-macos` `main`, fetched in full to `/private/tmp/claude-501/-Users-ghostxmerlin-tab5-starlight/627c741f-d6f9-4d7f-83ac-171112c94dbb/scratchpad/immurok-full/` (111 files; Info.plist says 1.6.5 build 488). Paths below are relative to that tree.
- **exia** — `/Users/ghostxmerlin/exia` (`Sources/Attestation.swift`, `stick/android/PixelLock/PROTOCOL.md`).
- **Atom firmware** — `/Users/ghostxmerlin/atom/aism/main/*` and `/Users/ghostxmerlin/atom/docs/*` (read only, not to be edited from this repo).

Effort scale used throughout: **S** = a day or two, host-only. **M** = roughly a week, may touch firmware lightly. **L** = multi-week, firmware + host + packaging. Risk is about security regressions and bricking the user's workflow, not schedule.

---

## 0. TL;DR

AISM's product identity is "the Claude-Code approval card that you approve with a fingerprint on Atom" (`AppState.handleBuddyControlCommand` at `Sources/CodeIsland/AppState.swift:2272-2293`, fed by Atom's `0xF0` which the firmware only emits after a fingerprint match — `~/atom/aism/main/buddy_link.h:22`). Everything borrowed from immurok should be framed as *more things an agent (or you) can be asked to approve with that same touch*: `sudo`, GUI admin dialogs, SSH signing, password fields. Not a pivot to a password manager.

The order of work is forced by one fact: AISM's phase-1 unlock trusts a **public constant key** (`BuddyFingerprintAttestation.fixedKey` at `Sources/CodeIslandCore/BuddyFingerprintProtocol.swift:230`, and `fp::kFixedKey` in firmware `fp_protocol.h:50`). With that key anyone can forge a valid unlock tag. A `sudo`/`authorization` PAM module that accepts the app's word would turn that into root. So phase-2 crypto (per-device key via ECDH, root-side MAC verification for PAM) has to land first.

### Roadmap (ordered)

| # | Item | What it buys | Effort | Risk | Default-off / reversible? |
|---|------|--------------|--------|------|---------------------------|
| 1 | **Phase-2 device key: ECDH P-256 + HKDF over the existing `0xD0` channel** (`ATTEST_SET` 0x40 repurposed as key agreement, `ATTEST_STATUS` 0x42 unchanged) | Removes the public constant; `canUnlock` becomes meaningful; prerequisite for everything below | M (host S, firmware M) | low — additive; phase-1 key stays as a fallback only while a `fp_debug` flag is on | Yes: firmware keeps answering with the fixed key until a per-device key is set; app refuses unlock when `keyMatches` fails exactly as today (`BuddyFingerprintChannel.swift:49-55`) |
| 2 | **Domain-separated `AUTH_CHALLENGE` op** (new `0xD0` op, e.g. 0x44, payload `purpose(1) + nonce`), reusing `Chunks32`/`unlockChallengeFrames` plumbing | One nonce/tag round usable for sudo, authorization, SSH, "agent approve", not just the lock screen; device can light/prompt by purpose | S host, S firmware | low | Yes |
| 3 | **PAM module `pam_aism.so` + `~/.codeisland/pam.sock` server + root-side key file `/etc/aism/pam/<uid>.key`** (port of `pam/*.c`, `PAMSocketServer.swift`, `PamKeyCommand.swift`), installed into `/etc/pam.d/sudo_local` **and** `/etc/pam.d/authorization` in one go. Strong mode only (no "bare OK" compat). | Touch-to-`sudo`; touch-to-approve System Settings / SecurityAgent admin dialogs without any injection | L (host M, C module S since it ports nearly verbatim, packaging M because `/etc/pam.d` needs an installer pkg) | **med-high**: touches the auth stack of the machine; must be fail-closed and uninstallable | Yes: `SKIP` → `PAM_IGNORE` keeps the stack falling through to password when the toggle is off (`pam_immurok.c:272-277`) |
| 4 | **"sudo from an AI agent" surfaced as an AISM approval card** — classify the PAM peer's ancestry against AISM's known `cliPid`s (`SessionSnapshot.cliPid`, `Sources/CodeIslandCore/SessionSnapshot.swift:167`) instead of immurok's path heuristics | This is the on-brand feature: the agent's `sudo` shows up next to its other permission requests and is approved with the same Atom touch | S–M | low | Yes |
| 5 | **AX set-value password autofill** for Apple Passwords / Apple ID / App Store (port `AuthInjector.swift`, `AuthContextDetector.swift`, `InjectionWhitelist.swift`, `AuthInjectionKit/*`) | Fills secure fields that PAM never sees (Passwords app unlock, App Store sign-in, Sign in with Apple) | M | **high** (it is password injection; the only thing making it acceptable is the hardening in §6.2) | Yes, per-target toggles like immurok's `AutomationItem.enabled` |
| 6 | SSH agent (`SSHAgentServer.swift`) with on-device ECDSA keys | Keys never leave Atom; `git push`/`ssh` gated by touch | L (host S — file ports almost verbatim; **firmware L**: keystore + P-256 signing + new ops) | med | Yes |
| 7 | TOTP Quick-Fill | Device-side TOTP typed on hotkey | M (firmware M) | low-med | Yes |
| 8 | OTA | — | **Skip immurok's code**: it is a WCH IAP bootloader protocol (`FirmwareUpdateKit/OTAEngine.swift:22-24`), useless for ESP-IDF. If wanted, use ESP-IDF's own OTA. | n/a | n/a |

Highest-leverage findings, up front:

1. **immurok's `authorization` trick needs no injection and no Secure-Event-Input fight**: it prepends `auth sufficient pam_immurok.so` to `/etc/pam.d/authorization` (`packaging/postinstall:60-67`), so SecurityAgent/System Settings dialogs succeed on an *empty* password once the PAM module says yes. That is the mechanism AISM should use for GUI admin dialogs. Details and the pre-auth subtlety in §6.1.
2. **immurok's root-side MAC model is small, self-contained and ports nearly verbatim** (`pam/pam_auth_verify.c`, 113 lines, plus `pam_immurok.c` 353 lines, plus ~90 lines of `ImmurokSecurity.swift:136-181`). Shared test vectors exist (`pam/vectors/pam-mac-v1.json`, used by both `pam/test_pam_mac.c` and `Tests/PamMacTests`). The one thing that does **not** port is the install-time peer verification by Developer ID (`CLISources/PeerCodeSignature.swift:19-23`) because AISM is ad-hoc signed (memory: no Developer ID). §3.3 proposes a substitute.
3. **AISM's challenge/response is already stronger than immurok's match notification.** immurok's `0x21` match is `HMAC(shared_key, [0x21][page_id])` with no nonce (`Sources/ImmurokSecurity.swift:85-111`) — replayable; freshness comes only from a per-connect challenge (`BLEManager.swift:2013-2046`) that is skipped when the peripheral UUID was seen before (`:2001-2011`). AISM's `UNLOCK_CHALLENGE` carries a fresh 32-byte nonce and a 14-byte tag per round (`BuddyFingerprintProtocol.swift:63-69, 239-250`). Keep AISM's shape; borrow immurok's key agreement, not its notification format.
4. **The AX set-value path is the right tool for app password fields, and the hardening is most of the value.** `AXUIElementSetAttributeValue(field, kAXValue, secret)` (`Sources/AuthInjector.swift:12`) and AX actions / synthesized mouse clicks (`:44, :66, :396-402`) are not subject to Secure Event Input, which immurok's own comments confirm blocks synthesized Return in secure fields (`:35, :70-72, :76-77`). But the detector's rules — owner-pid signature check, reject browser-owned fields unless native sheet and not inside `AXWebArea`, "exactly one secure field" — are what stop it from typing your login password into a web form (`Sources/AuthContextDetector.swift:34-69, 195-215`). Port both or neither.

---

## 1. Where AISM stands today (the base being grafted onto)

### 1.1 BLE layer and the `0xD0` fingerprint channel

- One CoreBluetooth central, one `BuddyLink` per selected Buddy, shared service `0000beef-…` with a write characteristic (WRITE + WRITE_NR) and a notify characteristic (`Sources/CodeIslandCore/ESP32Protocol.swift:63-65`). Streaming writes use `.withoutResponse` and drain on `peripheralIsReady` (`ESP32BridgeManager.swift:574-580, 1093-1098`).
- Application-layer pairing `E0 + hostId` → `E0/E1/E2`; the protocol file itself says this is **not** cryptographic (`ESP32Protocol.swift:49-57`). The fingerprint channel is only started after `.accepted` (`ESP32BridgeManager.swift:1133-1140`), and the firmware drops `0xD0` frames from unpaired connections (`~/atom/aism/main/buddy_link.h:20`).
- `0xD0` frames have their own unbounded, first-out, never-dropped lane in `BuddyWriteQueue` (`Sources/CodeIsland/BuddyWriteQueue.swift:22-30, 42-47, 58-64`). This was a hard requirement from the firmware side (`docs/buddy-fingerprint-protocol.md` §2.1) and is the thing that makes any new auth traffic viable.
- `BuddyFingerprintChannel` serializes **one in-flight request at a time** per link, stamps `reqId` 1..255, times out replies after 8 s, probes support with STATUS twice at 5 s (`Sources/CodeIsland/BuddyFingerprintChannel.swift:37-39, 57-75, 218-265`). Events are routed by `reqId` (`:182-194`). `CANCEL` bypasses the queue (`:175-178`).
- Op codes today: `STATUS 01, ENROLL_BEGIN 21, CANCEL 22, LIST 23, VERIFY 24, DELETE 25, ATTEST_SET 40, ATTEST_DELETE 41, ATTEST_STATUS 42, UNLOCK_CHALLENGE 43` (`BuddyFingerprintProtocol.swift:12-23`); the firmware answers `ATTEST_SET/DELETE` with `Invalid` in phase 1 — there is no `case` for them, they fall into `Engine::handle`'s `default:` branch (`~/atom/aism/main/fp_engine.cpp:179-181`; spec `2026-10-22-buddy-fingerprint-design.md:170`). `ATTEST_STATUS` hashes the constant (`fp_engine.cpp:119-127`) and `UNLOCK_CHALLENGE` reassembles the nonce via `Chunks32` (`:170-178`).
- Frames are ≤ 20 bytes; the 32-byte nonce goes as two `offset+16` chunks under one `reqId` (`BuddyFingerprintProtocol.swift:47, 63-69`; firmware `fp::Chunks32`, `fp_protocol.h:71-102`).

### 1.2 Phase-1 unlock (what must be upgraded)

- `BuddyFingerprintAttestation.fixedKey = "aism-fingerprint-phase1-test-key"` (`BuddyFingerprintProtocol.swift:230`); `expectedKeyFingerprint = SHA256(K)[0:8]` (`:231`); tag = first 14 bytes of `HMAC-SHA256(K, "EXIA-UNLOCK-v1\0" ‖ nonce)` (`:232-242`), verified constant-time **in the app** (`:245-250`). Firmware mirrors this with `kFixedKey` (`fp_protocol.h:50`, `fp_crypto.cpp:44-55`, `fp_engine.cpp:373`).
- `canUnlock = support == .supported && keyMatches && attest.hasFinger` (`BuddyFingerprintChannel.swift:53-55`); `keyMatches` compares the device-reported `SHA256(K)[0:8]` with the constant (`:49-51`).
- `FingerprintUnlockController` runs one round per lock with a fresh nonce, verifies the tag at `FingerprintUnlockController.swift:207`, then types the Keychain password via `LockScreen.enter` (`:222-246`). `LockScreen` (ported from exia) checks loginwindow by bundle id + executable path + `anchor apple` code requirement + visible window before every chunk (`Sources/CodeIsland/FingerprintUnlock/LockScreen.swift:43-72, 77-110`). Password lives in the login Keychain under `com.codeisland.app.fingerprint-unlock.password`, read with `interactionNotAllowed` (`UnlockPasswordStore.swift:13, 36-50`).
- Off by default with a warning (`Settings.swift:36, 184`; `FingerprintUnlockSection.swift:6-7`).

### 1.3 The approval center of gravity

- Claude Code's `PermissionRequest` hook is held open by `HookServer` and answered by `AppState.approvePermission` resuming the continuation (`AppState.swift:2164-2223`, resume at `:2212`).
- Atom's single-byte `0xF0` arrives as `BuddyUplinkEvent.command(.approveCurrentPermission)` (`ESP32Protocol.swift:124-128, 160-163`) and is wired to `appState.handleBuddyControlCommand` in `AppDelegate.swift:93-98`. The approval card shows a "press finger on Atom" hint when STATUS says a sensor with ≥1 enrolled finger is present (`FingerprintApprovalHint.swift:11-18`, `NotchPanelView.swift:2057-2061`), and the publisher re-reads STATUS whenever a session enters `waitingApproval` (`ESP32StatePublisher.swift:123-127`).
- Sessions already know the agent's process: `SessionSnapshot.cliPid` is filled from the bridge's `_ppid` (`SessionSnapshot.swift:167-168`, `AppState.swift:1453-1456`). This matters for item 4 of the roadmap.

### 1.4 Known constraints (verified)

- **Single BLE connection at the application layer.** The firmware's GATT server keeps one `s_conn_id`/`s_connected` and re-advertises on disconnect to "accept the next Mac" (`~/atom/aism/main/buddy.cpp:174-179, 271-275`). The controller is configured for 3 (`~/atom/aism/sdkconfig:763 CONFIG_BTDM_CTRL_BLE_MAX_CONN=3`) but the app code is single-connection; `tools/README.md` step 2 says to quit AISM before running `fpctl`. Memory notes confirm the atom session quits AISM via osascript for the same reason.
- **Write rate.** `ESP32StatePublisher.flush` pushes 10–25 frames per change and every 5 s (`ESP32StatePublisher.swift:87-108`; memory: ~80 writes/s observed). The `0xD0` lane sidesteps this for auth frames; anything new (PAM, SSH) must ride that lane, not the shared one.
- **BLE link is plaintext.** Characteristics are `ESP_GATT_PERM_WRITE` / `ESP_GATT_PERM_READ`, no `_ENC` variants, and there is no `esp_ble_gap_set_security_param` for BLE (`buddy.cpp:202-218`; `main.c:324-327` configures Classic BT SSP for the HFP side only). The firmware design doc explicitly defers LE Secure Connections to phase 2 (`~/atom/docs/superpowers/specs/2026-10-22-buddy-fingerprint-design.md:19-24`).
- **Stuck `.connecting`.** `didUpdateNotificationStateFor` error path only sets `lastError` (`ESP32BridgeManager.swift:1024-1029`); no retry. Any PAM feature that waits on the device must treat "link not `.connected`" as an immediate fail-to-password, never a hang.
- **Settings-open CPU spin** (memory). Not an auth issue, but the PAM/SSH settings pages must not add timers or AllowDuplicates scans.

---

## 2. How immurok is built, and what is device-agnostic

immurok's device protocol is entirely different from Atom's: custom 128-bit service UUIDs (`Sources/BLEManager.swift:17-19`), a command/response pair of characteristics, op codes `getStatus 0x01 … pairInit 0x30, pairConfirm 0x31, authRequest 0x33, gateCancel 0x37, challenge 0x38, keySign 0x65, keyOTPGet 0x69` (`:43-74`), a signed `0x21` match notification, OTA on a separate service. **None of `BLEManager.swift` (2531 lines) is reusable as code.** What is reusable:

| Layer | immurok file(s) | Device-agnostic? | AISM home |
|---|---|---|---|
| ECDH P-256 + HKDF key agreement, Keychain storage | `Sources/ImmurokSecurity.swift:24-78, 369-411` | Yes (CryptoKit) | new `CodeIslandCore/BuddyPairingCrypto.swift` + Keychain store next to `UnlockPasswordStore` |
| PAM channel MAC (prefix ‖ nonce ‖ user\0 ‖ service\0, 16-byte prefix) | `ImmurokSecurity.swift:142-181`; `pam/pam_auth_verify.{c,h}`, `pam/hmac_sha256.{c,h}`; vectors `pam/vectors/pam-mac-v1.json` | Yes | `CodeIslandCore/PamChannelMac.swift` + `pam/` directory in the AISM repo |
| PAM module (socket client, spinner, SIGINT via kqueue, REJECT kills sudo, strong/compat modes) | `pam/pam_immurok.c` | Yes (talks only to a unix socket) | `pam/pam_aism.c` |
| PAM socket server (peer uid check, pre-auth windows, service toggles, RETRY/REJECT/SKIP/BUSY) | `Sources/PAMSocketServer.swift:1-598` | Mostly; replace `bleManager.requestUnlock` with an Atom challenge | `Sources/CodeIsland/Auth/PamSocketServer.swift` |
| Root installer for the key file (`O_EXCL 0600`, `fchown`, `rename`, `.keyid 0644`) | `CLISources/PamKeyCommand.swift:69-156` | Yes, except the Developer-ID peer check | a small `aism-admin` CLI (new SwiftPM executable; `codeisland-bridge` is a hook forwarder and should stay that) |
| Agent-vs-manual caller classification | `Sources/AuthCallerClassifier.swift` | Yes | reuse the idea, but match against `SessionSnapshot.cliPid` first |
| AX injection + context detection + whitelist | `Sources/AuthInjector.swift`, `AuthContextDetector.swift`, `InjectionWhitelist.swift`, `AXAppProbe.swift`, `AuthInjectionKit/*` | Yes | new `Sources/CodeIsland/Autofill/` |
| Device-flow mutual exclusion | `AuthInjectionKit/DeviceActivityCoordinator.swift` | Yes | needed anyway: unlock vs sudo vs enroll vs approval all share one `0xD0` request slot |
| SSH agent protocol | `Sources/SSHAgentServer.swift` | Yes except `BLEManager.shared.sshSign` and `SSHKeyCache` | optional |
| TOTP Quick-Fill | `Sources/QuickFillPanel.swift` | UI yes; needs device-side TOTP | optional |
| OTA | `FirmwareUpdateKit/*`, `PAMSocketServer.swift:863-1238` | **No** — WCH IAP commands `0x80–0x85`, Image B 216 KB | skip |
| Screen unlock | `Sources/AppDelegate.swift:400-520` + `fakeKeyStrokes` | AISM already has the better version (`LockScreen.swift` checks code signature; immurok checks bundle id/localized name, `AppDelegate.swift isLoginWindowFrontmost`) | keep AISM's; borrow only the Apple-Watch-in-progress hold (`:484-502`) and the OpenDirectory re-verify-then-suspend idea (`ImmurokSecurity.swift:241-256`, `AppDelegate.swift:409-427`) |

Worth noting about immurok's weaker spots, so they are not copied:

- `verifyFingerprintMatch` has no nonce (`ImmurokSecurity.swift:85-111`); the 8-byte connect-time challenge (`:116-134`) is skipped for a cached peripheral UUID (`BLEManager.swift:2001-2011`).
- Pre-authorization windows (`PAMSocketServer.swift:89-155`) are a deliberate convenience with a replay-shaped risk: a touch now approves a PAM request within N seconds. immurok itself removed the worst case ("any service, 10 s" with no UI context — `AppDelegate.swift:365-373`). AISM should keep windows ≤3 s, service-scoped, and only where unavoidable (§6.1).
- Compat mode: a missing key file means bare `OK` is accepted (`pam_immurok.c:9-11`). For AISM, strong mode should be the only mode (§3.3).

---

## 3. Phase-2 security — the prerequisite

### 3.1 Why first

- Today the tag key is public. Any BLE peripheral advertising `0xBEEF`, accepting `E0` pairing (a 6-byte random host id, replayable — `ESP32Protocol.swift:49-57`), and knowing the string `aism-fingerprint-phase1-test-key` can answer any unlock challenge. The firmware doc says so (`docs/buddy-fingerprint-protocol.md` §10). The app's own settings UI warns about it (`FingerprintUnlockSection.swift:29-31`).
- If a PAM module is wired to the same signal, "forge an unlock tag" becomes "become root" (`sudo`) or "approve any admin dialog" (`authorization`). immurok mitigates the *second half* of that chain (a same-UID process impersonating the app's socket) with the root-side MAC; nothing mitigates a forged device if the device key is public. Both halves are needed.

### 3.2 Device key agreement (borrow `ImmurokSecurity.swift:34-78`)

Host side (CryptoKit, verbatim shape):

```
startPairing():   P256.KeyAgreement.PrivateKey() → compressedRepresentation (33 B)   // :34-38
completePairing(devicePub):
    shared = priv.sharedSecretFromKeyAgreement(devicePub)                            // :52
    K = HKDF-SHA256(shared, salt: "…pairing-salt", info: "…shared-key", 32 B)        // :55-60
    store K in Keychain (generic password)                                           // :66
```

Change the salt/info strings to AISM's own (`"aism-pairing-salt"`, `"aism-attest-key"`); keep 32 bytes so `K` drops straight into the existing tag math (`BuddyFingerprintAttestation.tag(nonce:key:)` already takes a key parameter — `BuddyFingerprintProtocol.swift:239-242`).

Mapping onto Atom's `0xD0` channel (this is the part immurok cannot help with — different op space):

| Step | Frame(s) Mac → Atom | Atom → Mac | Notes |
|---|---|---|---|
| 1. `ATTEST_SET` (0x40) becomes "begin key agreement" | `D0 40 id 00 + 16 B` then `D0 40 id 10 + 16 B` then `D0 40 id 20 + 1 B` (33-byte compressed app pubkey in three `offset+chunk` frames, same pattern as `unlockChallengeFrames`) | per-chunk `Ok + received`, final reply `WaitConfirm (1)` | Reuses the reserved op and the reserved result code the spec kept for exactly this (`spec:21-22, 170`). Firmware needs a `Chunks33` (or generalize `Chunks32` with a length parameter — `fp_protocol.h:71-102`). |
| 2. User presses Atom's button within 30 s | — | `D0 70 id Ok type=5 [00 + 15 B]`, `[0F + 15 B]`, `[1E + 3 B]` (device pubkey, 33 B, chunked as events) | Physical confirmation is the authentication of this exchange (TOFU); same as immurok's `WAIT_BUTTON` (`BLEManager.swift:749-756`) and exia's "B confirm" (`PROTOCOL.md:47`). |
| 3. Both derive `K`; Atom stores it in NVS and wipes the ephemeral private key | — | `D0 70 id Ok type=5 [done]` or `D0 70 id Timeout/Cancelled type=5` | Atom must never emit `K`; only `SHA256(K)[0:8]` via `ATTEST_STATUS` (already the design: `docs/buddy-fingerprint-protocol.md:82`). |
| 4. Verify | `D0 42 id` | `hasAttest=1, hasFinger, SHA256(K)[0:8]` | App replaces `expectedKeyFingerprint` (constant) with the fingerprint of the Keychain `K`. `keyMatches`/`canUnlock` logic is otherwise unchanged (`BuddyFingerprintChannel.swift:49-55`). |
| 5. `ATTEST_DELETE` (0x41) | `D0 41 id` | `WaitConfirm` → button → `Ok` | Forget/unpair also clears the Keychain `K`. |

Why ECDH and not exia's `ATTEST_SET` of a raw 32-byte `K` (`exia PROTOCOL.md:47`): with a plaintext link, exia's model puts `K` on the air once; ECDH never does, and a passive sniffer during pairing learns nothing. The remaining gap for both is an *active* MITM during pairing. immurok narrows it with LE bonding ("BLE bond already authenticates the device" — `BLEManager.swift:2002`); Atom has no display to show `SHA256(K)[0:8]` for a visual compare, so the honest statement is: **pairing is trust-on-first-use, authenticated by the button press within a short window and by the Mac displaying the key fingerprint; LE Secure Connections on the Atom side would close the active-MITM gap and is the firmware's own stated phase-2 item** (`spec:21`). Open question #1.

Per-round freshness: keep AISM's 32-byte nonce / 14-byte tag design exactly as is; it is already better than immurok's `0x21` notification. Optionally add immurok's connect-time device check (8-byte nonce → 8-byte HMAC, `ImmurokSecurity.swift:116-134`) as `ATTEST_STATUS` extension so `canUnlock` can be set early after reconnect — but do **not** copy the "cached UUID skips the challenge" fast path (`BLEManager.swift:2001-2011`).

Firmware cost: mbedTLS ships with ESP-IDF, so P-256 ECDH and HKDF are available; `fp_crypto.cpp`'s hand-rolled HMAC truncates messages to 64 bytes (`fp_crypto.cpp:29-31`) and must be generalized or replaced by `mbedtls_md_hmac` before any message longer than 64 bytes is MAC'd (the unlock message is 47 bytes today, but §3.4's PAM message is not sent to the device, so this only matters if purpose strings are added to the device-side tag).

### 3.3 Root-side verification for PAM (borrow `pam/*` and `PamKeyCommand.swift`)

The model, exactly as immurok does it:

1. The app generates a 32-byte `pam_key` once and stores it in its Keychain (`ImmurokSecurity.swift:162-173`). It is **independent of the device key** — re-pairing Atom does not invalidate sudo (`:136-140` comment).
2. A root step copies it to `/etc/aism/pam/<uid>.key`, owner root, mode 0600, created with `open(O_CREAT|O_EXCL|O_NOFOLLOW, 0600)` then `fchown(0,0)` then `rename` into place, umask 077 (`PamKeyCommand.swift:76, 108-146`). A world-readable `<uid>.keyid` (= `SHA256(key)[0:8]` hex) lets the app show "installed / mismatch" without root (`:147-149`; `SetupManager.swift:96-112`).
3. `pam_sm_authenticate` loads the key with `pam_load_key` (regular file, `(mode & 077) == 0`, size 32, owner root — `pam_auth_verify.c:14-35`), generates a 16-byte nonce (`:37-39`), sends `AUTH:<user>:<service>:<nonce_hex>` to `~<user>/.aism/pam.sock` (`pam_immurok.c:111, 126`), and only accepts `OK:<mac_hex32>` where `mac = HMAC-SHA256(key, "aism-pam-v1" ‖ nonce ‖ user ‖ \0 ‖ service ‖ \0)[0:16]` compared constant-time (`pam_auth_verify.c:57-93`; Swift twin `ImmurokSecurity.swift:148-155`).
4. Fail-closed rules worth copying verbatim (`pam_immurok.c:7-25, 85-107, 204-222`): key file present but unusable → still strong mode with `key_valid=0`, so every `OK` is denied and audited to `/var/log/aism-pam.log` (`pam_auth_verify.c:95-113`).
5. Response vocabulary (`PAMSocketServer.swift:5`, `pam_immurok.c:204-289`): `OK:<mac>` success; `RETRY:<n>` wrong finger, keep waiting; `REJECT` user explicitly refused → module `raise(SIGTERM)` + `_exit(77)` so `sudo` dies instead of falling to a password prompt (`:245-271`); `SKIP` feature off → `PAM_IGNORE`, silent fall-through (`:272-277`); `DENY`/`TIMEOUT`/`BUSY` → fall through to password. Ctrl-C is caught with a kqueue `EVFILT_SIGNAL` rather than a signal handler because libpam `dlclose`s the module (`:136-157`) — keep that; it is a real crash avoidance.

**Deviation 1 — no compat mode.** immurok accepts a bare `OK` when the key file is absent (`pam_immurok.c:9-11`). For AISM, absent key file should mean `PAM_IGNORE` (feature not set up), never "accept OK". The whole point of the root-side key is that a same-UID process that binds `pam.sock` first (exactly what `packaging/test-pam-spoof.sh:65-104` simulates) cannot mint root.

**Deviation 2 — install-time peer verification without Developer ID.** immurok's `imk pam-key install` refuses to fetch `PAM_KEY` from the app socket unless the socket's peer satisfies the app's Developer ID designated requirement, using `LOCAL_PEERTOKEN` so a pid-reuse/exec swap is caught (`CLISources/PeerCodeSignature.swift:19-59`; `PamKeyCommand.swift:89-90`). AISM builds are ad-hoc signed (memory `fork-distribution`; `build.sh:139-166` falls back to whatever identity exists), so the designated requirement is a per-build `cdhash` and this check cannot be reproduced as-is. Options, in order of preference:

   a. **Invert the data flow.** The root tool *generates* the key, writes `/etc/aism/pam/<uid>.key` (0600 root) and `<uid>.keyid` (0644), and hands the key to the user **once** through the sudo'd terminal's stdout (or a `0600` file in `~/.aism/` that the app consumes and deletes immediately on next launch, then stores in Keychain). The app then shows `keyid` from its Keychain next to the installed `keyid`; if they differ, strong auth is off. A same-UID spoofer could still read that handoff file in the window before the app consumes it — so prefer the terminal-stdout handoff plus a paste field in Settings, or do the handoff while the app is already running and listening (the tool connects to the app's socket as root and *pushes* the key; the app only accepts a `PAM_KEY_SET` from euid 0 — `PAMSocketServer.swift:277-288` already distinguishes root peers).
   b. Keep immurok's direction (root *reads* key from app) but verify the peer with `anchor apple generic`-less requirement `identifier "com.codeisland.app" and cdhash H"<this build>"` injected at build time. Brittle: breaks on every rebuild, and the user rebuilds often.
   c. Accept the risk and document it. Not recommended once `authorization` is wired.

   Either way, surface `pamKeyStatus` (installed / mismatch / not installed) in Settings like `SetupManager.swift:96-112`, and make `mismatch` disable the feature in the app so the user notices.

**Deployment reality check.** `/etc/pam.d/*` is SIP/TCC-protected: immurok's build script notes that only `system_installd` (an installer pkg) may write there and that `osascript`-elevated root was TCC-denied (`packaging/build-pkg.sh:138-141`). So AISM needs a `.pkg` with a `postinstall` like `packaging/postinstall` (prepend `auth sufficient /usr/local/lib/pam/pam_aism.so` to `sudo_local` and `authorization`, `chmod 444`) and an uninstall pkg like `packaging/uninstall-postinstall`. The `.so` itself can be ad-hoc signed (immurok's `pam/Makefile` defaults `SIGN_IDENTITY ?= -`) and must be a universal `-lpam` dylib. Unsigned/ad-hoc pkgs install with a Gatekeeper warning; that is the same posture as the current DMG. Open question #4 covers whether macOS 26 `sudo` loads an ad-hoc `.so` (immurok's default Makefile suggests yes; verify).

### 3.4 Putting the two keys together in a sudo round

```
sudo → pam_aism.so ── AUTH:user:sudo:nonce16 ──▶ AISM pam.sock server
                                                  │ (toggle on? link .connected? canUnlock?)
                                                  │ AUTH_CHALLENGE purpose=sudo, nonce32 ──▶ Atom (2 frames, 0xD0 lane)
                                                  │ ◀── event type 2: NoMatch… / Ok + tag14
                                                  │ verify tag with Keychain K (device key)
                                                  │ mac = HMAC(pam_key, "aism-pam-v1"‖nonce16‖user‖\0‖"sudo"‖\0)[0:16]
          ◀── OK:<mac_hex32> ───────────────────── │
pam_aism.so verifies mac with /etc/aism/pam/<uid>.key as root → PAM_SUCCESS
```

Two independent secrets: the device key proves "a finger matched on *this* Atom", the pam key proves "the answer came from the AISM process the user set up, not a socket squatter". Both are needed; neither alone is sufficient. BLE cost per sudo: 2 downlink frames + 1–2 uplink frames.

---

## 4. Capability-by-capability borrow plan

### 4.1 PAM `sudo` (item 3)

- **What it does:** `sudo` → `pam_immurok.so` → unix socket → app → device touch → `OK:<mac>`; terminal shows a spinner and "Approved!/Denied/Not matched, n left" (`pam_immurok.c:57-62, 204-289`).
- **immurok files:** `pam/pam_immurok.c`, `pam/pam_auth_verify.{c,h}`, `pam/hmac_sha256.{c,h}`, `pam/Makefile`, `pam/test_pam_mac.c`, `pam/vectors/`, `Sources/PAMSocketServer.swift`, `Sources/ClientDisconnectWatcher.swift` (Ctrl-C detection), `Sources/TerminalSpinner.swift` (not needed; PAM module draws its own spinner), `AuthInjectionKit/DeviceActivityCoordinator.swift`.
- **Port / rewrite / skip:** Port the C module with renames (`immurok` → `aism`, socket `~/.aism/pam.sock` or better `~/.codeisland/pam.sock` to match AISM's existing config dir, key dir `/etc/aism/pam`, log `/var/log/aism-pam.log`) and the strong-only deviation. Port `pam_auth_verify.c` and the Swift MAC verbatim with the prefix changed to `aism-pam-v1`; regenerate vectors with `pam/gen_vectors.py`. Rewrite `PAMSocketServer.handleClient` (`:274-567`) around `BuddyFingerprintChannel`: replace `bleManager.requestUnlock` (`:491-506`) with a `startAuthChallenge(purpose:nonce:)` that returns `.noMatch` events as `RETRY`, drop `pendingRequestSemaphore`/proactive-approval logic (`:29-32, 66-79`) because Atom has no unsolicited match notification — the device only identifies when asked or when the red approval light is on (`fp_engine.cpp approval()`, `fp_engine.h:37`).
- **AISM plumbing:** new `0xD0` op `AUTH_CHALLENGE` (§3.2 table item 2) so the device can distinguish lock-screen unlock (preempts approval — `fp_engine.cpp challenge()` calls `preemptApproval()`) from a sudo request (should probably *not* preempt a pending Claude approval, or should, by policy — open question #6). The host-side mutual exclusion between unlock controller, PAM server, enrollment manager and SSH must be explicit: port `DeviceActivityCoordinator` and have `FingerprintUnlockController.challenge()` (`:164-194`) and `BuddyFingerprintManager` (`:49-102`) acquire it, otherwise two `0xD0` requests queue in `BuddyFingerprintChannel` and the second silently waits 8 s.
- **Link state:** `AUTH` must answer `DENY` immediately when no `fingerprintChannels` has `canUnlock` (`ESP32BridgeManager.swift:261-263`) — mirrors `PAMSocketServer.swift:389-399`. Never block on reconnect (immurok's SSH path sleeps up to 5 s waiting — `SSHAgentServer.swift:293-308`; do not copy that into PAM).
- **Settings:** two toggles (`sudo`, `authorization`) default off, exactly `isServiceEnabled` (`PAMSocketServer.swift:158-169`), plus the `pamKeyStatus` indicator and an "Install/Repair PAM" button that opens the pkg. immurok also watches for macOS upgrades stripping the `authorization` line and notifies (`SetupManager.swift:59-86`, `AppDelegate.swift:960-972`); worth copying since the upgrade loses the feature silently.

### 4.2 PAM `authorization` — GUI admin dialogs (item 3, same module)

See §6.1 for the mechanism. Code-wise it is the same socket server; the service string arrives as `authorization` (`pam_immurok.c:342-345` passes `PAM_SERVICE`). Differences from `sudo`:

- There is no terminal, so RETRY/Approved text goes nowhere; AISM should show state in the notch panel (reuse the approval card UI with a "System is asking for admin rights" variant). `REJECT` (`raise(SIGTERM)` in the host process) must **not** be used for `authorization` — the host is `authorizationhost`/SecurityAgent, not `sudo`; return `PAM_AUTH_ERR` instead. immurok's module does not special-case this; check what `raise(SIGTERM)` does inside `authorizationhost` before enabling REJECT there (open question #5).
- UX flow choice (§6.1): "press Return on the empty dialog, then touch" needs no pre-auth and no synthetic keystrokes. immurok's "touch first, app presses Return for you" needs a 3 s service-scoped pre-auth and a synthesized Return.

### 4.3 AX set-value password autofill (item 5)

- **What it does:** on a fingerprint match with no pending PAM request and an unlocked screen, detect a whitelisted password field, set its value with the AX API, then submit via the dialog's default button / AX confirm action / synthetic mouse click (`AppDelegate.swift:277-315`; `AuthInjector.swift`).
- **Targets shipped:** App Store (Apple ID password, multi-step wizard), Passwords app + `AKAuthorizationRemoteViewService` (Sign in with Apple) + Safari's native Passwords sheet (login password), 1Password desktop (its own unlock password), Bitwarden browser extension (`AuthInjectionKit/AutomationItem.swift:84-112`; secrets per target in `InjectionPolicy.swift:51-59` and `SecretKind.swift`).
- **Port / rewrite / skip:** Port `AuthInjectionKit` (pure logic, has tests under `Tests/AuthInjectionKitTests`), `AuthInjector.swift`, `AuthContextDetector.swift`, `InjectionWhitelist.swift`, `AXAppProbe.swift`, `BrowserExtensionDetector.swift` (only if Bitwarden is wanted). The trigger differs: immurok fires on an unsolicited device match (`BLEManager.swift:2294-2314` → `onFingerprintMatch`). Atom never sends unsolicited matches, so AISM needs an explicit trigger: a global hotkey (immurok has `GlobalHotKey.swift` for Ctrl-\) that runs `AuthContextDetector().detect()`, and **only if** a whitelisted field is found, sends an `AUTH_CHALLENGE purpose=autofill` to Atom, waits for the tag, then injects. This ordering (detect → challenge → inject) is actually safer than immurok's (match → detect → inject) because the touch is requested *for* a specific, already-verified target, and the notch card can name it.
- **Device-agnostic:** entirely. Nothing here touches BLE except the challenge round.
- **Secrets:** separate Keychain items per target like immurok (`ImmurokSecurity.swift:15-19`); reuse `UnlockPasswordStore`'s pattern (`interactionNotAllowed`, zero after use).
- **Risk control:** ship each target behind its own toggle, default off, and ship Apple-platform targets (Passwords / App Store / Sign in with Apple, all `anchor apple` code-signature checked — `InjectionPolicy.swift:12-15`, `InjectionWhitelist.swift:43-49`) before any third-party target. 1Password/Bitwarden are Chromium web forms with geometric button hunting (`AuthInjector.swift:75-154`); they are the brittle part and the least on-brand for AISM.

### 4.4 SSH agent (item 6, optional)

- **What it does:** `~/.immurok/agent.sock` speaks the SSH agent protocol (REQUEST_IDENTITIES, SIGN_REQUEST — `SSHAgentServer.swift:7-11`), sets `SSH_AUTH_SOCK` via `launchctl setenv` (`:45-56`), forwards `SHA256(data)` to the device for ECDSA P-256 signing after a touch (`:310-365`), returns `ecdsa-sha2-nistp256` signatures (`:382-401`). Public keys are cached in `~/.immurok/ssh_keys.json`; private keys never leave the device (`SSHKeyCache.swift:1-8`).
- **Port:** host file is ~470 lines and device-agnostic apart from `BLEManager.shared.sshSign(idx:hash:)` and the `SSHKeyCache` sync. It would port in a day **once the device can sign**.
- **Device side (the real cost):** Atom has no keystore. Needed: NVS-backed slots (name + P-256 keypair), `KEY_GENERATE`, `KEY_GETPUB`, `KEY_SIGN(idx, hash32)` gated by a fingerprint match, `KEY_DELETE`, all as new `0xD0` ops; 32-byte hash down = 2 frames; 64-byte signature up = 5 event frames of ≤15 bytes (or raise the firmware's 20-byte frame cap and negotiate MTU, which the current design explicitly avoids — `docs/buddy-fingerprint-protocol.md:23`). mbedTLS ECDSA on ESP32 is fine; immurok's device takes up to 15 s for a sign on its MCU (`SSHAgentServer.swift:364`), the ESP32 will be far faster.
- **Interaction with the single-connection constraint:** none beyond the shared `0xD0` slot; a sign request is one challenge round.
- **Verdict:** valuable, but it is a second product (hardware SSH key). Do after 1–5, if at all.

### 4.5 TOTP Quick-Fill (item 7, optional)

- **What it does:** Ctrl-\ opens a panel listing device entries; picking an OTP entry sends `KEY_OTP_GET(idx, unix_time)`; device computes TOTP after a touch; the app types the 6 digits with CGEvent `keyboardSetUnicodeString` into the focused field (`QuickFillPanel.swift:197-223, 443-449`). Typing a 6-digit code is not into a secure field, so Secure Event Input is not a concern there.
- **Port:** panel UI is device-agnostic; device needs secret storage + HMAC-SHA1 TOTP + a new op. M on firmware, S on host. Lowest fit with AISM's identity; keep on the backlog.

### 4.6 ECDH pairing (item 1)

Covered in §3.2. Borrow `ImmurokSecurity.swift:34-78` verbatim (CryptoKit), keep Keychain helpers (`:369-411`), swap the salt/info strings. Device-facing frames are AISM's own (`ATTEST_SET`/`ATTEST_DELETE`/`ATTEST_STATUS` + event type 5), not immurok's `PAIR_INIT`/`PAIR_CONFIRM`.

### 4.7 OTA (item 8) — skip

`FirmwareUpdateKit/OTAEngine.swift:22-24, 36-50` and `PAMSocketServer.swift:863-1238` implement the WCH "IAP" bootloader protocol (`CMD_IAP_PROM 0x80 … CMD_IAP_HEADER 0x85`, Image B at 216 KB) over a dedicated OTA GATT service. Atom is ESP-IDF with its own partition table (`~/atom/aism/partitions.csv`) and ESP-IDF OTA APIs. Nothing here transfers; the `.imfw` format and header signing belong to immurok's BSL-licensed firmware anyway (§8). If AISM wants firmware updates later, that is an ESP-IDF OTA design (likely Wi-Fi/HTTPS, since BLE at 20-byte frames is slow), not a port.

### 4.8 `imk run --agent` approval overlay (bonus, item 4)

- `imk run --agent -- cmd` asks the app (`AGENT_APPROVE:<cmd>` over `pam.sock` — `CLISources/AgentApproval.swift:9-14`), the app shows an overlay with the command, waits for a touch, then arms a 10 s `sudo` pre-auth and writes a `~/.immurok/markers/<pid>` file so a later `sudo` in the same process tree is classified as agent-initiated (`PAMSocketServer.swift:611-710`; `AgentMarker.swift:12-56`; `AuthCallerClassifier.swift:21-48`).
- AISM already *is* the approval overlay for agents, with real session identity. Rather than porting the marker files, classify the PAM peer by walking its ancestry (`AuthCallerClassifier.swift:160-176` has the `proc_pidpath`/`sysctl` helpers; `Sources/CodeIslandBridge/main.swift:79-95` has AISM's own `parentPID`/`buildAncestry`) and matching against `sessions[*].cliPid`. A hit means "this sudo came from Claude session X" → enqueue it as a `PermissionRequest`-like card for that session with the command line (available from the sudo process's argv via `proc_pidinfo`/`sysctl KERN_PROCARGS2`; immurok gets it from the marker instead — open question #7), approve on Atom touch, answer the PAM socket. A miss (manual sudo in a terminal) → no card, device still gates it silently, as immurok does (`PAMSocketServer.swift:408-435`). The agent-binary path list (`AuthCallerClassifier.swift:93-116`) is a reasonable fallback for agents AISM doesn't track.

---

## 5. Firmware / device-side implications (for the `~/atom` project; nothing edited here)

What exists: `fp::Engine` with modes `Idle/Enroll/Verify/Unlock/Approval` (`fp_engine.h:37`), `Chunks32` nonce reassembly (`fp_protocol.h:71-102`), `unlockTag` with `kFixedKey` (`fp_crypto.cpp:44-55`, `fp_engine.cpp:373`), `ATTEST_STATUS` hashing `kFixedKey` (`fp_engine.cpp:119-123`), `ATTEST_SET/DELETE → Invalid`. Mutual exclusion rules in `docs/buddy-fingerprint-protocol.md` §6.

Needed, in roadmap order:

1. **Per-device key in NVS** replacing `kFixedKey` at the two use sites; `ATTEST_STATUS.hasAttest` becomes real (0 when no key), `UNLOCK_CHALLENGE` returns `NoAttest (14)` when unset (the spec reserved both — `spec:22, 190`). Keep a compile-time `FP_PHASE1_FIXED_KEY` fallback for bring-up only.
2. **ECDH over `ATTEST_SET`** (§3.2): chunked 33-byte app pubkey in, `WaitConfirm`, button press within 30 s (there is already a 30 s pair-confirm window — `buddy_link.h:82 kPairTimeoutMs`), P-256 ECDH + HKDF (mbedTLS), chunked 33-byte device pubkey out as events, store `K`, wipe ephemerals. `ATTEST_DELETE` with button confirm. Error paths: timeout, cancelled, busy (reject while Enroll/Verify/Unlock in progress, same as `challenge()`).
3. **`AUTH_CHALLENGE` op with a purpose byte** (sudo / authorization / autofill / ssh / agent) so LED/UI can differ and so the tag can be domain-separated: `HMAC(K, "AISM-AUTH-v1\0" ‖ purpose ‖ nonce)`. Decide whether it preempts a pending red-light approval (`challenge()` currently calls `preemptApproval()` for the lock screen — probably right for unlock, questionable for a background `sudo`).
4. **Generalize `hmacSha256`** (`fp_crypto.cpp:25-42` silently truncates messages to 64 bytes) or switch to `mbedtls_md_hmac` before adding purpose bytes.
5. Later, for SSH: keystore + `KEY_*` ops (§4.4). For TOTP: secret slots + `OTP_GET` (§4.5).
6. **Link security (independent of all of the above):** LE Secure Connections + bonding and `_ENC` characteristic permissions (`buddy.cpp:202-218`) is the firmware's declared phase-2 item (`spec:21`). It is what turns TOFU pairing into authenticated pairing. CoreBluetooth will prompt once for the bond; `ESP32BridgeManager` needs no code change for encryption itself but the reconnect path must tolerate the pairing prompt.

Constraints to respect:

- **Single connection:** no new connections; everything stays on the existing link. `fpctl` and AISM still cannot coexist; document it in the PAM setup page ("quit fpctl / the atom session before testing sudo").
- **Write rate:** all new traffic is `0xD0` and tiny (≤ 5 frames per operation). The 15–30 ms, latency-0 connection parameters the firmware now requests (`buddy.cpp:162-172`) make a challenge round sub-second; the publisher's 80 writes/s shared lane is unaffected because `0xD0` goes first (`BuddyWriteQueue.swift:58-64`).
- **One in-flight `0xD0` request:** both `BuddyFingerprintChannel` and the firmware enforce it. The host-side `DeviceActivityCoordinator` port (§4.1) is what keeps a sudo request from being queued behind an enrollment for 8 s and timing out.

---

## 6. The two techniques that beat naive injection

Both exist because, as the user verified separately and immurok's comments corroborate, **CGEvent keystrokes do not reach SecurityAgent's secure field while Secure Event Input is active** (`AuthInjector.swift:35` "secure field + SEI 可能拦", `:70-72`, `:76-77` "聚焦密码框时 Secure Event Input 开启，合成回车被拦"). AISM's `LockScreen.enter` works only because loginwindow's lock screen is the exception that accepts them (verified on macOS 26 per `LockScreen.swift:20-21`).

### 6.1 `authorization` PAM service for GUI admin dialogs — authenticate instead of type

Mechanism (verified in code):

- `postinstall:60-67` prepends `auth sufficient /usr/local/lib/pam/pam_immurok.so` to `/etc/pam.d/authorization`; `:27-44` does the same for `sudo_local`. Uninstall strips both lines (`uninstall-postinstall:14-41`).
- `authorizationhost`/SecurityAgent evaluates the `authorization` PAM stack when the user submits the dialog. Because the module is `sufficient` and returns `PAM_SUCCESS` after the device touch, the dialog is satisfied **with an empty password field**; the password is never typed anywhere. AppDelegate's comment ties the three dialog kinds together: "System Settings sheet, SecurityAgent standalone window for Chrome/etc. all map to the `authorization` PAM service" (`Sources/AppDelegate.swift:340-347`).
- The PAM module sees `PAM_SERVICE == "authorization"` (`pam_immurok.c:342-345`) and the app gates it with its own toggle (`PAMSocketServer.swift:162-163`).

How immurok makes the dialog *submit* so PAM runs (`AppDelegate.swift:332-373`):

- If a system-wide focused `AXSecureTextField` exists (`isSecureInputFocused`, `:722-731`): arm a **3 s pre-auth scoped to `{"authorization"}`** (`PAMSocketServer.setPreAuthorization`, `:89-119`) and post a synthesized Return (`sendEnterKey`, `:933-937`). The dialog submits an empty password → PAM → module connects → app consumes the pre-auth → `OK:<mac>`.
- If a Touch ID sheet is showing (`findUsePasswordButton`, `:735-…`, found by `AXSheet` containing "Touch ID"/"触控" text): `AXUIElementPerformAction(button, kAXPress)` on the last button ("Use Password…"), arm the 3 s pre-auth, Return after 0.5 s (`:353-364`).
- No recognized context → **no pre-auth at all** (`:365-373`), because an unscoped window was "the most exploitable path".

Two cautions for AISM:

1. immurok relies on a synthesized Return reaching SecurityAgent (`:351, :363`). That is in tension with the SEI finding above — a bare Return on an *empty* secure field may behave differently from typing text, or the behaviour may differ by macOS version; immurok also has a heuristic that detects the window expiring unconsumed (`PAMSocketServer.swift:53-58, 103-118`), which suggests it does not always fire. **Prefer AX actions for the submit** — `AXUIElementPerformAction(defaultButton, kAXPressAction)` or `kAXConfirmAction` on the field (`AuthInjector.swift:41-45, 64-69`) — which immurok itself notes are not SEI-blocked (`:83`). Open question #3.
2. The pre-auth window exists only because immurok's device matches *first* (unsolicited `0x21`) and the PAM request arrives *after*. With Atom, the natural order is reversed and simpler: **user presses Return/OK on the empty dialog → PAM request arrives → AISM challenges Atom → user touches → `OK:<mac>`.** No pre-auth, no synthetic keys, no AX probing, one extra Return by the user. Ship that as the default; offer the touch-first convenience later, service-scoped and ≤3 s, if users want it.

Coverage caveat: which rights actually route through the `authorization` PAM service (System Settings padlock, "X wants to make changes", Keychain Access prompts, installer, `security` CLI…) has to be tested per dialog on macOS 26. Open question #2.

### 6.2 AX set-value for app password fields — plus the hardening that makes it tolerable

The write (`Sources/AuthInjector.swift`):

- `inject`: `AXUIElementSetAttributeValue(field, kAXValueAttribute, secret)` (`:11-15`) — bypasses the keyboard path entirely.
- `focus`: `kAXFocusedAttribute = true`, else synthesized mouse click at the field's center (`:17-24`); mouse events are not SEI-filtered (`:396-402`).
- `submit`: (0) window's `AXDefaultButton` + `kAXPress` (`:41-45`); (1) language-independent main-button pick excluding Cancel/traffic-light subroles and cancel titles, preferring confirm-ish titles, else rightmost (`MainButtonSelector.swift:27-77`, `:48-62`); (2) `kAXConfirmAction` on the field (`:64-69`); (3) synthesized Return as last resort, explicitly "may be blocked by SEI" (`:70-72, 219-228`).
- Chromium targets (1Password/Bitwarden) need geometric button location + synthesized click because `AXPress` is a no-op there (`:75-154`). App Store needs a wizard driver (`:230-276`).

The guard rails (`Sources/AuthContextDetector.swift` + `InjectionWhitelist.swift`), each of which AISM should keep:

1. **Match by the field's owner pid, not the frontmost app**, then require the owner to pass a code-signature check for the whitelisted bundle id (`:34-39`; `InjectionWhitelist.swift:12-19, 36-59`). Apple targets: `anchor apple and identifier "<bundle>"`; third-party: `anchor apple generic` + `kSecCodeInfoTeamIdentifier == teamID` (not `leaf[subject.OU]`, which fails for Mac App Store builds — `:28-35`). Bundle ids and team ids are character-whitelisted before being spliced into a requirement string (`IdentityValidation.swift`, `InjectionPolicy.swift:42-46`).
2. **Browser-owned secure fields are refused unless** the field's container is a native `AXSheet` **and** the ancestry does not cross `AXWebArea` (`:15-22, 40-48, 146-160`). This is the rule that prevents filling the login password into a web login form in Safari.
3. **Downward scans require exactly one secure field in the app's tree** (`:52-69, 185-215`) — excludes "change master password" forms with current/new/confirm fields. Browser processes are never scanned downward (`:56-59`).
4. **Generic-strategy targets must be frontmost** (`:61`); background windows are never filled.
5. **Unresponsive AX trees are skipped** with a 0.2 s probe (`AXAppProbe.swift:13-33`), so a modal-blocked Chrome does not stall the whole flow.
6. **Per-target toggles, default off; identity fields of built-ins are read-only** (`AutomationItem.swift:17, 56-74, 84-112`).
7. **Lock suppression after an auth flow**, so a lingering finger does not immediately re-lock (`AppDelegate.swift:630-641`) — Atom-specific equivalent: ignore `0xF1`/button during the 2 s after a fill.

For AISM add an eighth: **the touch is requested after detection and names the target** (§4.3), so the user approves "fill Apple ID password into App Store", not "something".

---

## 7. Roadmap detail (per item: scope, S/M/L, risk, kill switch)

1. **Phase-2 device key (ECDH)** — host S: `BuddyPairingCrypto` (port of ~45 lines), Keychain item, `ATTEST_SET` chunked encode (copy of `unlockChallengeFrames`), event type 5 parsing, `expectedKeyFingerprint` from Keychain, "Pair key with Atom" button in `BuddyFingerprintSection`, unit tests alongside `BuddyFingerprintProtocolTests`. Firmware M. Risk low; kill switch: without a stored `K`, `keyMatches` is false and `canUnlock` is false (existing behaviour). **Ship before anything else.**
2. **`AUTH_CHALLENGE` op** — host S (one op, one purpose byte, same `startUnlock` path generalized to `startAuth(purpose:)`), firmware S. Risk low.
3. **PAM module + socket server + root key** — C module S (port), Swift server M, admin CLI S, pkg/postinstall/uninstall M, strong-only policy, tests: `pam/test_pam_mac.c` + Swift vectors + a port of `packaging/test-pam-spoof.sh` (bare `OK` and bad-MAC spoofs must be denied and audited). Risk med-high; kill switches: toggles → `SKIP`/`PAM_IGNORE`; uninstall pkg strips the `pam.d` lines; the module never *adds* a failure mode when the socket is absent (connect fails → `PAM_AUTH_ERR` → falls through to password — `pam_immurok.c:121-124`; consider returning `PAM_IGNORE` there instead so a missing app is silent).
4. **Agent-sudo as an approval card** — S–M: ancestry match to `cliPid`, card variant, answer path. Risk low. Kill switch: falls back to silent device gating.
5. **AX autofill (Apple targets first)** — M: port kit + detector + injector + whitelist + per-target settings + hotkey trigger + challenge-before-inject. Risk high by nature; mitigated by §6.2 rules and default-off. 1Password/Bitwarden strategies: later or never.
6. **SSH agent** — host S after firmware L. Risk med (a stuck sign hangs `git push` until the 50 s timeout; keep immurok's client-disconnect watcher — `SSHAgentServer.swift:344-353`). Kill switch: `restoreAuthSockEnv` (`:58-69`).
7. **TOTP** — M, optional.
8. **OTA** — skip immurok's; separate ESP-IDF design if ever.

Every item is additive and behind a default-off toggle; none changes how Claude Code approvals work today.

---

## 8. Licensing

- immurok `app-macos` is **Apache-2.0** including the PAM module (`README.md`, final section; `LICENSE` is the standard Apache 2.0 text). Device firmware is **BSL 1.1 and lives in a different repository** — nothing from it is in this tree and nothing from it may be copied into `~/atom`. The `.imfw` header layout and OTA command set visible in `FirmwareUpdateKit`/`PAMSocketServer.swift:863-1238` describe that firmware's interface; do not reimplement them for Atom (there is no reason to anyway).
- Copying or adapting immurok Swift/C into AISM requires (Apache-2.0 §4): keep the license; add a `NOTICE` (or a section in AISM's existing third-party notices) stating that portions are derived from immurok app-macos, Copyright the immurok authors, licensed under Apache-2.0, with a link; **mark modified files** ("modified from immurok `Sources/PAMSocketServer.swift`" in the header) — §4(b) requires prominent notices of changes; retain any copyright/attribution comments present in copied files (the files read carry none beyond the header comments, so a per-file provenance line suffices). AISM itself (CodeIsland fork) — check upstream's license for compatibility; Apache-2.0 code can be included in MIT/Apache projects with the NOTICE carried along, but not relicensed.
- Test vectors (`pam/vectors/pam-mac-v1.json`) are data under the same license; regenerate them for AISM's own prefix anyway.
- Trademark: do not keep the immurok name in paths, bundle ids, socket names or UI.

---

## 9. Open questions / things to verify on real hardware

1. **Pairing authentication without a device display.** Is TOFU + button press + Mac-side key-fingerprint display acceptable until Atom has LE Secure Connections? Can the Atom Voice's LEDs encode anything useful (e.g., blink pattern of 2 bytes of `SHA256(K)`)? Does CoreBluetooth bonding with an ESP32 that turns on `_ENC` permissions survive AISM's reconnect/legacy-fallback logic (`ESP32BridgeManager.swift:687-707`)?
2. **Which GUI dialogs route through `/etc/pam.d/authorization` on macOS 26?** Test: System Settings padlock; "Installer wants to make changes"; a third-party app's `AuthorizationCopyRights` prompt (Chrome keychain, Homebrew cask `sudo`); Keychain Access unlock; `security unlock-keychain`; Screen Time / parental controls. immurok's code asserts the first and the SecurityAgent standalone window (`AppDelegate.swift:340-347`) but not the rest.
3. **Does a synthesized Return reach SecurityAgent's empty secure field** under Secure Event Input? immurok relies on it (`AppDelegate.swift:351, 363`); the user's test found CGEvent typing blocked. If blocked, use `AXDefaultButton`/`kAXConfirmAction` (`AuthInjector.swift:41-45, 64-69`) or adopt the user-presses-Return flow (§6.1).
4. **Ad-hoc-signed PAM module loading.** Confirm `sudo` and `authorizationhost` on macOS 26 `dlopen` an ad-hoc-signed universal `.so` from `/usr/local/lib/pam/` (immurok's Makefile defaults to ad-hoc — `pam/Makefile SIGN_IDENTITY ?= -`). Confirm the pkg `postinstall` can write `/etc/pam.d/*` (immurok says only `system_installd` can — `build-pkg.sh:138-141`).
5. **`REJECT` inside `authorizationhost`.** `raise(SIGTERM)` + `_exit(77)` is designed for `sudo` (`pam_immurok.c:245-271`). Determine the effect inside SecurityAgent's PAM host before allowing REJECT for the `authorization` service; otherwise return `PAM_AUTH_ERR` there.
6. **Preemption policy on the device.** Should an `AUTH_CHALLENGE` for `sudo` preempt a pending red-light Claude approval the way the lock-screen challenge does (`fp_engine.cpp challenge() → preemptApproval()`)? Which touch wins when both are waiting? Needs a decision and a firmware rule (spec §5.3 covers unlock vs approval only).
7. **Command line for the agent-sudo card.** immurok displays the command because `imk run --agent` wrote it to a marker (`AgentMarker.swift`). AISM would read the sudo process's argv (`KERN_PROCARGS2`) or the `PreToolUse` cache for that session (`AppState+ToolUseCache.swift:194`). Verify argv is readable for a `sudo` process owned by the same uid (setuid binaries may hide it).
8. **Install-time key handoff without Developer ID** (§3.3 option a vs b). Confirm the Keychain ACL behaviour for an ad-hoc app across rebuilds — the protocol doc already warns items may need re-saving after rebuild (`docs/buddy-fingerprint-protocol.md:235`) — because a `pam_key` that silently becomes unreadable turns strong mode into "always falls back to password" (safe, but confusing).
9. **PAM timeouts vs Atom's unlock semantics.** PAM module waits 40 s (`pam_immurok.c:54`); Atom's unlock round has no time limit and self-restarts the sensor every ~8 s (`docs/buddy-fingerprint-protocol.md:112`). The app must send `CANCEL` when the PAM client goes away (port `ClientDisconnectWatcher`) and when its own timer expires, or Atom keeps waiting for a finger and the button stays dead.
10. **Sensor-removed detection latency.** `present` only drops after 12 s of silence (`fp_engine.h:21`); a `sudo` issued in that window gets `SensorError` late. Decide whether `AUTH` should pre-check `STATUS` (one extra round trip) or accept the delay.
11. **Does `hmacSha256`'s 64-byte message cap** (`fp_crypto.cpp:29-31`) ever bite with the domain-separated message (`15 + 1 + 32 = 48` bytes — currently no, but it is a trap for the next change).
12. **Settings-open CPU spin** (memory) — unrelated to auth but the new PAM/SSH settings pages must not add polling; verify with `sample` after adding them.

---

## Appendix A — file map immurok → AISM (proposed)

| immurok | lines | → AISM (new unless noted) |
|---|---|---|
| `Sources/ImmurokSecurity.swift` ECDH/HKDF part | 24-78 | `Sources/CodeIslandCore/BuddyPairingCrypto.swift` |
| `Sources/ImmurokSecurity.swift` PAM MAC part | 142-181 | `Sources/CodeIslandCore/PamChannelMac.swift` (+ tests with regenerated vectors) |
| `pam/pam_immurok.c`, `pam_auth_verify.{c,h}`, `hmac_sha256.{c,h}`, `Makefile`, `test_pam_mac.c`, `gen_vectors.py` | all | `pam/` in the AISM repo, renamed `pam_aism` |
| `Sources/PAMSocketServer.swift` | 1-598 (not 599-1238) | `Sources/CodeIsland/Auth/PamSocketServer.swift`, device calls rewritten onto `BuddyFingerprintChannel` |
| `Sources/ClientDisconnectWatcher.swift` | all | same name |
| `AuthInjectionKit/DeviceActivityCoordinator.swift` | all | `Sources/CodeIsland/Auth/DeviceActivityCoordinator.swift`; adopt in `FingerprintUnlockController`, `BuddyFingerprintManager` |
| `CLISources/PamKeyCommand.swift` | 69-209 | new SwiftPM executable `aism-admin` (`pam-key install/remove/status`), peer check replaced per §3.3 |
| `packaging/postinstall`, `uninstall-postinstall`, `test-pam-spoof.sh` | all | `packaging/` |
| `Sources/AuthCallerClassifier.swift` | 21-48, 150-176 | `Sources/CodeIsland/Auth/AuthCallerClassifier.swift`, with `cliPid` match first |
| `AuthInjectionKit/*`, `Sources/AuthInjector.swift`, `AuthContextDetector.swift`, `InjectionWhitelist.swift`, `AXAppProbe.swift` | all | `Sources/CodeIsland/Autofill/` (item 5) |
| `Sources/SSHAgentServer.swift`, `SSHKeyCache.swift` | all | optional (item 6) |
| `Sources/BLEManager.swift`, `FirmwareUpdateKit/*`, OTA handlers | — | **not ported** |

## Appendix B — AISM touch points per item

- Item 1: `BuddyFingerprintProtocol.swift` (new event kind, attest frames, replace `fixedKey` usage), `BuddyFingerprintChannel.swift:49-55` (`keyMatches` source), `BuddyFingerprintSection.swift` (pair/forget key UI), tests in `Tests/CodeIslandCoreTests/BuddyFingerprintProtocolTests.swift` and `Tests/CodeIslandTests/BuddyFingerprintChannelTests.swift`.
- Item 2: `BuddyFingerprintOp` (+ `authChallenge`), `BuddyFingerprintRequest.unlockChallengeFrames` generalized with a purpose byte, `FingerprintUnlockController.challenge()` (`:164-194`) uses purpose `unlock`.
- Item 3: new `Auth/` folder; `AppDelegate.swift:86-99` starts the socket server next to `FingerprintUnlockService.shared.start()`; `SettingsView.swift:2137-2147` gains a "System auth" section; `Settings.swift` gains `pamSudoEnabled`, `pamAuthorizationEnabled` (default false); `Package.swift` gains the `aism-admin` executable.
- Item 4: `AppState.swift:2023-2060` (`handlePermissionRequest`) gets a sibling for PAM-originated requests; `NotchPanelView.swift:2057-2061` hint reused.
- Item 5: new `Autofill/` folder; `GlobalHotKeyManager.swift` (exists) for the trigger.
