# Relay 配对 v2：配对码 + Numeric Comparison

* Task: 260823T0142-relay-pairing-code-sas
* Author: Huanan
* Status: DEVELOPING
* Type: FEAT
* Related: [260816T1953-agent-status-v1](../260816T1953-agent-status-v1)

## Outcome

把 Mac ↔ iPhone 的配对从"扫一个装满秘密的 JSON 二维码"改成"一个 6 位配对码 + 一次数字比对"：

1. iPhone 配对只需要一个 **6 位配对码**（字母 + 数字，不分大小写）。扫码、手输、手输 + 自定义 Relay 三种入口都落到同一条协议。
2. 配对完成前，Mac 和 iPhone **各显示 6 位数字**（Bluetooth Numeric Comparison），Mac 上点一次 **Match** 才生效。这一下同时完成"允许这台 iPhone"和"确认中间没人换钥匙"。
3. iPhone 端 **Relay 地址不再写死**：每台已配对 Mac 各自记住自己的 Relay；二维码里带 Relay 地址 + 配对码；手输时默认用内置 Relay，可在 Advanced 里改。
4. Relay 仍然只做路由与授权，仍然读不到、存不了任何 Session 内容；配对过程里 Relay 拿不到任何能让它冒充 Mac 或 iPhone 的材料。
5. 旧的 JSON offer 二维码、`pairing-offers` / `pair` 端点、iOS 的"Relay URL 必须等于内置值"检查全部删除，不保留兼容路径。

## 信任模型（设计的出发点）

| 角色 | 信任程度 | 依据 |
|---|---|---|
| Mac daemon | 完全信任 | 数据源头 |
| iPhone | 配对后信任 | 只读；凭据在 Keychain |
| Relay | **不信任**（诚实但好奇 → 可能作恶） | 自托管 Worker，但账号 / 平台可能被攻破 |
| 看得到 Mac 屏幕的人 | 不信任 | 能抄到配对码 |
| 网络上的路人 | 不信任 | 能猜码、能发请求 |

三层防线，每层独立：

1. **配对码**（30 bit，5 分钟，单次）：路人找不到 Mac、也进不了门。
2. **承诺 + SAS**（6 位数字）：Relay 换钥匙只有一次盲猜机会（10⁻⁶），失败人眼可见。
3. **Mac 点 Match**：没有 Mac 前的人点头，任何设备都拿不到 Device token。

Relay 地址本身不承载信任：恶意地址最多让 iPhone 配上一台"假 Mac"，碰不到真 Mac 的通道。

## 用户流程

### Mac（Pairing 页）

```
┌──────────────────────────────────┐
│  Pair an iPhone                  │
│                                  │
│   ▓▓▓▓▓▓▓     Code   7KF 3QP     │   QR = agentstatus://pair?relay=…&code=7KF3QP
│   ▓▓ QR ▓▓    Relay  afuture.workers.dev
│   ▓▓▓▓▓▓▓     Expires in 4:31    │   5 分钟到点自动换码
│                                  │
│  ─── Paired iPhones ───          │
│  Huanan 的 iPhone   Active [Revoke]
└──────────────────────────────────┘
          │ iPhone 提交后
┌──────────────────────────────────┐
│  "Huanan 的 iPhone" wants to pair │
│                                  │
│          482 913                 │
│  Compare with the number on the  │
│  iPhone.                         │
│     [Don't match]    [Match]     │   60 秒无操作 = Don't match
└──────────────────────────────────┘
```

- 结果态（Paired / Pairing declined）在同一张卡就地显示 2 秒，然后收起、开始新码；iPhone 中途取消则不显示结果，直接开始新码。
- 离开页面 = 取消会话，码立刻作废；daemon 重启 = 会话作废，重开页面即可。

### iPhone（Macs 页 → Add Mac）

```
┌─────────────────────────┐      ┌─────────────────────────┐      ┌─────────────────────────┐
│  Add Mac                │      │  Huanan MBP             │      │  Huanan MBP             │
│                         │      │  afuture.workers.dev    │      │  Paired · syncing…      │
│  [7][K][F] [3][Q][P]    │  →   │                         │  →   │                         │
│  [Scan code]            │      │       482 913           │      └─────────────────────────┘
│  ▸ Advanced             │      │  Confirm on your Mac    │
│     Relay URL  https://…│      │  [Cancel]               │
└─────────────────────────┘      └─────────────────────────┘
```

- 三个入口：
  - **扫码**：App 内扫描器，或系统相机扫到 `agentstatus://` 弹"在 Agent Status 中打开"。两个字段都从 URL 来。
  - **手输（默认）**：只敲码；Relay = 内置默认值。
  - **手输 + Advanced**：展开填 Relay URL；记住上次填的值（`LocalSettings`），自托管多台 Mac 通常共用一个 Relay。
- 错误文案固定四种：码不对 / 已过期（留在输入屏，Try again）；Mac 不在线（Try again 在**同一个会话**上重新提交设备，不重新 claim）；Mac 拒绝了（Start over）；校验失败（"Relay 返回的数据不一致，请换个网络重试"，Try again / Cancel）。Mac 那边换码或到期按第 ① 种处理（回到输码屏）。
- 取消：任一端取消，另一端在 1 秒内得知（iPhone 轮询 / Mac 的 `pairing_closed`）。

## 协议

Mac daemon 是**发起方**（先承诺），iPhone 是响应方，Relay 是不可信邮差。

```mermaid
sequenceDiagram
    participant A as Mac App
    participant D as daemon
    participant R as Relay
    participant I as iPhone

    A->>D: IPC relay_pairing_start
    D->>D: nonceH = random(32); commit = H("commit"‖hostPub‖nonceH)
    D->>R: POST /v1/hosts/:h/pairing-sessions {commit, hostPublicKey, hostName, expiresAt}   [Host secret]
    R->>R: HostRelay 建 session（取消该 Host 上一个活会话）；Directory 分配唯一 code
    R-->>D: {sessionID, code, expiresAt}
    D-->>A: relay_pairing_state → 显示 code + QR

    I->>R: POST /v1/pairing/claim {code}
    R->>R: Directory: H(code) 命中 → consumed；HostRelay: offered → claimed
    R-->>I: {sessionID, hostID, hostName, commit}

    I->>I: deviceKeyPair、deviceID（同 Mac 复用）
    I->>R: POST …/pairing-sessions/:s/device {deviceID, deviceName, devicePublicKey}   [sessionID]
    R->>R: claimed → submitted（Host 不在线则 409 host_offline，留在 claimed）
    R-->>D: Host WSS 控制帧 {type:"pairing_device", sessionID, deviceID, deviceName, devicePublicKey}

    D->>D: SAS = f(hostID, deviceID, hostPub, devicePub, nonceH)
    D-->>A: relay_pairing_state → pending {deviceName, sas}
    D->>R: POST …/:s/reveal {hostNonce}   [Host secret]
    R->>R: state = revealed

    loop 1 s 轮询
        I->>R: GET …/pairing-sessions/:s   [sessionID]
    end
    R-->>I: {state: revealed, hostPublicKey, hostNonce}
    I->>I: 校验 H("commit"‖hostPub‖hostNonce) == commit，否则中止
    I->>I: 算 SAS → 显示

    Note over A,I: 人比对两边的 6 位数字
    A->>D: IPC relay_pairing_decide {approved: true}
    D->>R: POST …/:s/decision {approved: true}   [Host secret]
    R->>R: 插 / 覆盖 devices 行；签发 deviceToken；state = approved
    D->>D: 钉住 devicePub（状态文件）；refreshDevices
    R-->>I: GET → {state: approved, deviceToken, pairedAt}
    I->>I: Keychain 存通道；开 Device WSS；sync_index
```

会话状态单向：`offered → claimed → submitted → revealed → approved | rejected | cancelled | expired`（claimed = 码已被花掉；submitted = 设备信息已进来）。reject 在 submitted / revealed 都允许；approve 只在 revealed。

### 为什么承诺让 SAS 只有 6 位也够

Relay 要骗过两端，必须同时：

- 对 iPhone 伪造 `commit'`——**此时还没见过 devicePub**；
- 对 Mac 伪造 `devicePub'`——**此时只见过 commit，不知道 nonceH**。

两边的 SAS 在它能"适应"之前就被钉死，相等概率 10⁻⁶；失败一次就是一次可见的 Don't match。没有承诺的话，攻击者可以离线枚举约 1000 对假钥匙凑出相同 SAS——所以 **reveal 必须由 daemon 在收到 devicePub 之后才发**，不能预先交给 Relay。

## 规格

### 配对码

| 项 | 值 |
|---|---|
| 字母表 | Crockford Base32：`0123456789ABCDEFGHJKMNPQRSTVWXYZ`（去 I L O U） |
| 长度 | 6 位 = 30 bit ≈ 1.07 × 10⁹ |
| 生成 | Relay `PairingDirectory` 取 30 bit 随机切片；与活跃码碰撞则重抽 |
| 显示 | 大写，`XXX XXX` |
| 输入归一化 | 大写；去空格 / 连字符；`O→0`，`I→1`，`L→1`，`U→V` |
| 有效期 | 5 分钟；单次消费；过期即删 |
| 存储 | Directory 只存 SHA-256(code) |

### QR / 链接

```
agentstatus://pair?relay=<url-encoded https URL>&code=<6 位码>
```

- iOS 注册 URL scheme `agentstatus`；App 内扫描器和 `SceneDelegate.openURLContexts` 都进同一配对状态机。
- 不用 Universal Link：它要求 App 预声明固定域名，与 Relay 可变冲突。
- `relay` 校验：`https`；有 host；无 userinfo / query / fragment；host 小写、去尾 `/`；长度 ≤ 256。DEBUG 构建额外允许 `http://localhost:*` / `http://127.0.0.1:*`（`wrangler dev`）。
- 二维码由 Mac App 用 daemon 给的 `code` + daemon 自己的 `relayURL` 拼出。

### 密码学

| 项 | 规格 |
|---|---|
| sessionID | 128 bit 随机 base64url；是 iPhone 后续三个调用的 capability |
| nonceH | 32 字节随机 |
| commit | `SHA256("Agent Status Relay/pair-commit/v1" ‖ hostPub ‖ nonceH)` |
| SAS | `SHA256("Agent Status Relay/pair-sas/v1" ‖ hostID ‖ deviceID ‖ hostPub ‖ devicePub ‖ nonceH)` 前 4 字节 big-endian `mod 1_000_000`，补零 6 位，显示 `XXX XXX` |
| Device token | Relay 在 approve 时生成 32 字节随机 base64url，只存 hash（同现在） |
| 通道密钥 | **不变**：X25519 + HKDF-SHA256（salt `Agent Status Relay/v1`，info `hostID‖deviceID`）+ ChaChaPoly |
| 顺手加固 | `sequence` 与 `kind` 进 AAD；`rate_limits` 窗口清理——两项都已随本任务落地 |

SAS 不混入 Relay URL（攻击者本来就控制 Relay），也不混入 Device token（token 在 SAS 之后才存在）。

## Relay

### Durable Objects

**新增 `PairingDirectory`**（全局单例，`getByName("directory")`）

```sql
CREATE TABLE pairing_codes (
  code_hash   TEXT PRIMARY KEY NOT NULL,
  host_id     TEXT NOT NULL,
  session_id  TEXT NOT NULL,
  expires_at  INTEGER NOT NULL,
  consumed_at INTEGER
);
```

- RPC：`allocate(hostID, sessionID, expiresAt) → code`（与活跃码碰撞则重抽）；`claim(code, sourceIP) → {outcome:"claimed", hostID, sessionID} | {outcome:"invalid"} | {outcome:"rate_limited"}`（先限流、再归一化、再原子标 consumed；对错都计数）；`release(hostID, sessionID)`（会话在被 claim 前结束时忘掉码）。每次写入顺手删过期行。
- Worker 入口拿到 `claimed` 后再调 HostRelay 把会话 offered → claimed；会话已不在 offered 也回 `404 invalid_or_expired_code`。
- 它只知道"哪个码属于哪个 Host"，不知道 commit、公钥、设备。

**`HostRelay`**（每 Mac 一个，现有）

```sql
CREATE TABLE pairing_sessions (
  id                TEXT PRIMARY KEY NOT NULL,
  state             TEXT NOT NULL,          -- offered|claimed|submitted|revealed|approved|rejected|cancelled|expired
  commit_hash       TEXT NOT NULL,
  host_public_key   TEXT NOT NULL,
  host_name         TEXT,
  host_nonce        TEXT,                   -- reveal 后才有
  device_id         TEXT,
  device_name       TEXT,
  device_public_key TEXT,
  device_token_hash TEXT,                   -- approve 后才有
  device_token      TEXT,                   -- approve 后才有；留给 iPhone 下一次轮询领取
  created_at        INTEGER NOT NULL,
  expires_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);
```

- 删表 `pairing_offers`。`devices`、`metadata`、`rate_limits` 不变。
- 状态只能单向前进；任何非法跳转 `409 invalid_state`。
- 同一 Host 同时只有一个活会话（offered / claimed / submitted / revealed）：新建会话先把上一个标 cancelled 并 `release` 它的码。
- 过期 session 在下一次访问时标 `expired` 并 `release` 它的码；已经看到设备（submitted / revealed）的会话过期或被 iPhone 取消时，给 Host WSS 发 `pairing_closed`。

### REST

| Method | Path | 鉴权 | 作用 |
|---|---|---|---|
| `GET` | `/health` | — | 不变 |
| `PUT` | `/v1/hosts/:h` | — | 注册 Host secret（不变） |
| `POST` | `/v1/hosts/:h/pairing-sessions` | Host secret | 建 session + 领 code → `{sessionID, code, expiresAt}` |
| `POST` | `/v1/pairing/claim` | 无（限流） | `{code}` → `{sessionID, hostID, hostName, commit}` |
| `POST` | `/v1/hosts/:h/pairing-sessions/:s/device` | sessionID | iPhone 提交 `{deviceID, deviceName, devicePublicKey}`；Host 不在线 → `409 host_offline` |
| `GET` | `/v1/hosts/:h/pairing-sessions/:s` | sessionID | `{state, hostName, hostPublicKey?, hostNonce?, deviceToken?, pairedAt?}`（字段按 state 逐步出现） |
| `POST` | `/v1/hosts/:h/pairing-sessions/:s/reveal` | Host secret | `{hostNonce}` |
| `POST` | `/v1/hosts/:h/pairing-sessions/:s/decision` | Host secret | `{approved}`；approved → 写 devices、签 token |
| `DELETE` | `/v1/hosts/:h/pairing-sessions/:s` | Host secret 或 sessionID | 取消 |
| `GET` | `/v1/hosts/:h/devices` | Host secret | 不变 |
| `DELETE` | `/v1/hosts/:h/devices/:d` | Host secret | 不变 |
| `GET` | `/v1/hosts/:h/ws` | Host secret / Device token | 不变 |

删除：`POST /v1/hosts/:h/pairing-offers`、`POST /v1/hosts/:h/pair`。

sessionID 鉴权：`Authorization: Bearer <sessionID>`，timing-safe 比较。

### Host WSS 控制帧（新增）

```json
{"type":"pairing_device","sessionID":"…","deviceID":"…","deviceName":"…","devicePublicKey":"…"}
{"type":"pairing_closed","sessionID":"…","reason":"cancelled|expired"}
```

与现有 `presence` / `error` 同一通道；daemon 的 `ControlMessage` 解码器加两种 type。`pairing_closed` 只在会话已到 submitted / revealed（daemon 已经看到设备）后才发：`cancelled` = iPhone DELETE 了会话，`expired` = Relay 在访问时发现会话过期。

### 限流与上限

| 动作 | 限制 |
|---|---|
| `claim` | 每来源 IP 5/min；Directory 全局 60/min（对错都计数） |
| 建 session | 每 Host 10/min |
| session 并发 | 每 Host 同时只有一个活会话；新建即取消上一个 |
| session 有效期 | Relay 最长接受 10 分钟；daemon 用 5 分钟 |
| `GET session` 轮询 | 不单独限流（sessionID 本身是 capability） |
| `rate_limits` 表 | 开新窗口时顺手删 10 个窗口期之前的旧行（已落地） |

## daemon（`RelayHostService`）

- 配对状态机住在 daemon：Mac App 退出不影响进行中的配对（与 Host WSS 在 daemon 里一致）。
- 新状态：`pairing: {sessionID, code, expiresAt, nonceH, pending: {deviceID, deviceName, devicePublicKey, sas}?}`，内存即可；daemon 重启 = 配对作废（用户重开一次）。
- 流程：`start` → POST session → 显示；收到 `pairing_device` → 算 SAS → POST reveal → 等 decide；60 秒无 decide 自动 reject；`decide(true)` → POST decision → **钉住该设备公钥（状态文件）** → `refreshDevices()`；到期 daemon 清空会话，Mac App（页面可见时）随即 `start` 一个新码。
- **钉住规则**：`GET devices` 列出的公钥只在与状态文件里钉住的值相同时才被相信；其余（这台 Mac 没批准过的行、Relay 换过的钥匙）Unverified——不发帧、请求丢弃、Mac 显示 `Key not verified · pair this iPhone again`。删除 `bindingSecret` / `keyBinding`。
- 新 IPC（`IPCRequest` / `IPCResponse`）：

| 操作 | 用途 |
|---|---|
| `relay_pairing_start` | 开始 / 续一个配对；返回 `{sessionID, code, relayURL, expiresAt}` |
| `relay_pairing_state` | `{code, relayURL, expiresAt, pending: {deviceName, sas}?, outcome: {approved|rejected|cancelled, deviceName}?}`，没有会话时为空；Mac App 配对页可见时 1 秒轮询 |
| `relay_pairing_decide {approved}` | Match / Don't match |
| `relay_pairing_cancel` | 离开页面 / 用户取消 |

- 删除 `relay_create_pairing_offer`。`relay_status`、`relay_revoke_device`、`relay_refresh_devices` 不变。
- daemon Keychain 内容不变（Relay URL、Host ID、Host secret、密钥对）。

## Mac App

- 设计稿：`~/Downloads/design_handoff_relay_pairing_v2 3`（macOS 第 2 页）；`DESIGN SYSTEM.html` 已同步到仓库根目录。
- 页头在内容区里：标题 `Pair an iPhone`（22/400）+ 右侧 Relay 药丸 + 一行说明 + 1px 分隔线；工具栏只剩侧栏开关（没有标题、没有 New code）；不挂 subheader 附件。
- 内容区左右贴窗口边缘（28 pt 内距，无 900 pt 阅读宽度上限）：左列（配对码卡 + pending 卡）最小 420、按内容撑开，Relay 地址单行不折不省；右列 Paired iPhones 列表随窗口伸缩、不被拉伸到左列高度。
- 配对码卡：QR 180 + `CODE` `7KF-3QP`（一个文本，连字符灰）+ `RELAY` host + `Expires in m:ss` + 倒计时条 + 说明 + `New code`；起码失败时错误写在卡里并 30 秒退避重试，不弹窗。
- pending 卡：`“<iPhone>” wants to pair` + host · 时间 + 64pt SAS + 说明 + `Don't match`（默认焦点）/ `Match`（Return 不绑定）+ 脚注；结果态只有 Paired ✓ / Pairing declined ✕，2 秒后收起并换新码；iPhone 中途取消不显示结果、直接换码。
- Paired iPhones 行：图标 + 名称 + 状态 tag（Active 绿 L2 / Revoked、Unverified 灰 L1）/ Relay host 副标题 / 行尾文字动作（Active、Unverified → `Revoke`；Revoked → `Remove` 删记录，经 `relay_remove_device` → `DELETE …/devices/:d?purge=1`，daemon 同时忘掉钉住的钥匙）；计数只算 Active；刚配对的行高亮一次。

## iOS App

- `RelayDeviceCredentials.relayURL` 以配对时选定的为准；删 `makeChannel` 里的覆盖与 `offer.relayURL == 内置` 检查；`RelayBuildConfiguration.url` 降级为"手输默认值"。
- 每条通道的 REST / WSS 客户端用自己的 URL（结构已是 per-channel）。
- Add Mac 页：6 格码输入（字母数字键盘、自动大写、粘贴整串识别）+ `Scan code` + 折叠 `Advanced › Relay URL`（记住上次）。
- `PairingScannerViewController` 保留，改为解析 `agentstatus://pair` URL。
- 注册 `CFBundleURLTypes: agentstatus`；`SceneDelegate` 处理 `openURLContexts`。
- `RelayDeviceController.pair(using:)` 换成状态机（`RelayPairingAttempt`）：`claim → submitDevice → poll(revealed) → verifyCommit → showSAS → poll(approved) → addChannel`；任何一步失败**不落 Keychain**。`host_offline` 的 Try again 保留 claim 结果、只重新提交设备（码已花掉，不能再 claim）。
- SAS 页与 Macs 页卡片显示 Relay host。
- 相机权限描述改为"扫描 Mac 上的配对码"。

## 安全分析

| 威胁 | 控制 | 剩余 |
|---|---|---|
| 路人猜码 | 2³⁰ × 5 min × 限流 ≈ 300 次 → ≈ 3×10⁻⁷；猜中仍需过 Mac Match | 可忽略 |
| 偷看屏幕抄到码 | 能走到提交设备，但 Mac 弹"陌生 iPhone 想配对" | 用户误点 Match |
| Relay 换钥匙（MITM） | 承诺 + SAS：一次盲猜 10⁻⁶，失败可见 | 用户不比对就点 Match |
| Relay 冒充 iPhone 取 token | token 只在 Mac `decision{approved}` 后签发，且签给 Mac 看到的那把 devicePub；Relay 若换了 devicePub，通道密钥对不上、SAS 也对不上 | — |
| 恶意 QR / 链接指向攻击者 Relay | 攻击者 Relay 没有真 Mac 的 code / Host secret，只能扮演"假 Mac"推假数据；iPhone 泄露的只有设备名、设备公钥、`session_reviewed` 的 session ID | 用户被假数据误导；靠界面显示 Relay host |
| 手输错 Relay URL | https + 格式校验；连不上 / 404 明确报错；连到别人家 Relay 时 code 对不上 | 无害 |
| 重放 / 重复使用 session | sessionID 一次性、state 单向、到期清理 | — |
| Relay 读正文 | E2E 不变 | 元数据同现在（多了 hostName、设备名、配对时间） |
| 路由头篡改 | `sequence` / `kind` 进 AAD | — |
| 与现状对比 | 多了 Mac 确认 + MITM 检测 + Relay 可变；少了 256 bit 带外秘密 | 净提升 |

## 失败与超时

| 情况 | 行为 |
|---|---|
| 码不对 / 过期 | iPhone 提示重输；Mac 端码到点自动换 |
| Mac daemon 离线 | claim 成功、提交设备 `409 host_offline` → iPhone 提示"Mac 不在线" |
| daemon 收到 `pairing_device` 但 Mac App 不在 | daemon 照常 reveal 并等 60 秒；没人点 → reject；iPhone 提示"Mac 拒绝了这次配对"（与 Don't match 不区分） |
| 60 秒无 Match | daemon reject → iPhone 轮询看到 rejected |
| commit 校验失败 | iPhone 中止、DELETE 会话、不存凭据、提示"校验失败"（唯一红色失败态） |
| 任一方取消 | DELETE session；另一方 1 秒内得知（轮询 / `pairing_closed`）；Mac 不显示结果、直接换新码；iPhone 回到输码屏（按 ① 处理） |
| Relay DO 重启 | session 在 SQLite，继续；code TTL 照旧 |
| daemon 重启 | 内存状态丢失 → session 到期自然作废；用户重开 Pairing 页 |
| 同一 iPhone 重配同一 Mac | deviceID 复用；approve 时覆盖 devices 行（新公钥、新 token、撤销清零）；daemon 在 Match 时用新公钥替换钉住值 |

## 不变的部分

- Host 注册、Host secret、Device token 的哈希存储与比较方式。
- 通道加密、序号、`sync_index` 对账、presence、撤销、Revoked 态处理。
- Mac 的 Relay URL 仍是 daemon 启动配置；Mac Keychain 内容不变。
- Relay 不存 Session、不做重放缓冲、没有 APNs。

## 验收证据

- **Common**：Base32 生成 / 归一化黄金用例；commit / SAS 派生黄金向量（Swift 与 TS 各算一遍相等，放进 `transport-v1.json` 同类 fixture）；`agentstatus://pair` URL 解析与拒绝用例。
- **Relay（vitest）**：code 唯一 / 过期 / 单次；状态机全部合法路径与每条非法跳转；`host_offline`；限流；approve 写 devices + token 可用于 WSS；reject / cancel / expired 不签 token；Directory 不泄露 commit。
- **daemon**：`pairing_device → reveal → decide` 全流程（InMemory REST）；60 秒自动 reject；到期续码；daemon 重启后旧 session 不可续。
- **iOS**：claim → submit → poll → verify → approved 状态机；commit 不匹配不落 Keychain；两条通道指向两个不同 Relay 同时在线；Advanced URL 记忆。
- **Mac**：配对页状态渲染（code / pending / 列表）快照。
- **端到端**：`wrangler dev` + 真 daemon + iOS 模拟器跑一遍扫码与手输两条路径；线上 Relay 部署后 `/health` 与一次真机配对。
- **文档**：`docs/feat/`（index、模块、旅程、摩擦点、数据流）的配对 Happy Path 改为"输码 → 对数字 → Mac 点 Match"；`docs/design/relay-pairing-security.md` 的配对流程、端点表、安全边界表重写；`docs/design/data-communication-storage.md` 的 IPC 表与 Keychain 表更新；`Relay/README.md`。

## 落地顺序（每步可独立 review / 提交）

1. **Common**：Base32、URL 解析、commit / SAS 派生 + 黄金向量；`RelayRoutingFrame` AAD。
2. **Relay**：`PairingDirectory` DO、`pairing_sessions` 状态机、新端点、控制帧、限流清理、测试；同一提交删旧端点（两端一起发布，不留兼容）。
3. **daemon**：配对状态机 + 4 个 IPC；删 `relay_create_pairing_offer`。
4. **Mac App**：Pairing 页。
5. **iOS**：凭据 per-Relay、Add Mac 页、扫描器改 URL、URL scheme、状态机、SAS 页。
6. **文档** + 部署 Relay + 真机验收。

## 决策记录

| 决策 | 结论 | 原因 |
|---|---|---|
| 配对码字符集 | 6 位 Crockford Base32（30 bit） | 比 6 位数字强 1000 倍，输入长度不变，去掉易混字符 |
| 谁生成配对码 | Relay Directory | 保证唯一；码不参与密钥，谁生成都一样 |
| SAS 表现形式 | 6 位数字，不用 emoji | 两端并排看屏幕（Bluetooth / Matrix 场景）；数字可本地化、不受 emoji 画风影响；Matrix 正在废弃 emoji |
| SAS 长度 | 6 位 + 承诺 | 有承诺时 10⁻⁶ 足够；没承诺 6 位不安全 |
| PAKE | 不做 | CryptoKit 无现成实现；"码 + 承诺 SAS + Mac 确认"已覆盖同一威胁 |
| QR | 保留，但只装 `relay + code` | 替用户填两个字段；不再承载秘密以外的东西 |
| Relay 地址 | iPhone 每台 Mac 各自记录；手输默认内置值，可改 | 同一 iPhone App 配任意自托管 Relay |
| Mac 侧 Relay 地址 | 不动（启动配置） | 不在本任务范围 |
| 旧路径 | 全删 | 三端同发，不留兼容分支 |

## 风险

- 配对过程从 1 次请求变成 6 次请求 + 轮询，对 Relay 可用性更敏感；用 60 秒 / 5 分钟两个超时兜底。
- 用户可能不比数字直接点 Match——UI 文案要把数字放在按钮正上方、按钮默认焦点放在 `Don't match`。
- 系统相机扫 `agentstatus://` 的横幅行为依赖 iOS 版本；App 内扫描器是主路径。

## 实施状态（2026-08-23）

已完成并验证：

- Relay（vitest 21）、Common Remote / Transport、daemon（RelayHostServiceTests 11）、Mac（pairing / client 4）、iOS（34）单测全绿。
- 端到端：`wrangler dev` + 隔离 daemon + iOS 模拟器走通 码 → 提交 → 两端 SAS 一致 → Match → 通道建立；线上 Relay 已部署（版本 `b5c28e5a`，含 purge），线上 claim / 起码均验证过。
- Mac 配对页、iOS Add Mac / SAS / 失败态 ①② 有无头快照或模拟器截图核对。

未验收 / 注意：

- 真机 iPhone 尚未走一遍；此版本之前配对过的 iPhone 在新 daemon 眼里是 Unverified，必须用新构建重新配对（不留兼容，设计内代价）。
- Mac 的 pending 卡 / 结果态只有单测与代码审阅，没有截图（快照导出器抓不到 60 秒内的状态）。
- Debug 构建的 Mac App 在窗口激活时会崩在 `RoundedSelectionRowView.interiorBackgroundStyle` 的执行器检查（Sessions 列表的既有问题，与配对无关）；Release 不受影响，已单独记为任务。
- 已审批的配对会话里 Device token 明文留在 `pairing_sessions` 直到到期清理（≤ 10 分钟）。

## References

- [Bluetooth LE Secure Connections — Numeric Comparison](https://www.bluetooth.com/blog/bluetooth-pairing-part-4/)
- [Telegram E2E voice calls：带承诺的 DH 与 SAS](https://core.telegram.org/api/end-to-end/voice-calls)
- [Matrix MSC4405：废弃 emoji SAS](https://github.com/matrix-org/matrix-spec-proposals/pull/4405)
- [Dechand et al., USENIX Security '16：文本指纹表示](https://www.usenix.org/conference/usenixsecurity16/technical-sessions/presentation/dechand)
- [Crockford Base32](https://www.crockford.com/base32.html)
- 现状设计：[relay-pairing-security.md](/docs/design/relay-pairing-security.md)、[data-communication-storage.md](/docs/design/data-communication-storage.md)
