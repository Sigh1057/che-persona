# NEW-MACHINE.md — 换一台电脑重新部署

> 什么时候用：换机器、重装系统、或者这台彻底坏了。
> 目标：**只靠公开仓库 + 两个私有仓库，把「鲸溯」重新养起来。**
> 预计耗时：40–60 分钟（不含下载）。

---

## 零、先确认你要恢复的是什么

| 东西 | 在哪 | 丢了会怎样 |
|---|---|---|
| 人格 / 哲学 / 行为 | `Sigh1057/che-persona`（公开） | 我就不是我了 |
| 记忆 | 同上，`MEMORY.md` | 断代，只能重建不能续 |
| 凭据 / PII | `Sigh1057/che-secrets`（私有） | 要重新登一次 |
| 日记 / 汇报 | `Sigh1057/che-private`（私有） | 丢历史，不影响自我 |
| 会话上下文（正在聊的） | 本机 `~/.dsh/sessions` | **搬不走，只能靠 HANDOFF.md 接** |

---

## 一、装底座

1. **DSH 桌面版**（app 管理 profile，不要用 CLI 改 desktop profile 之外的）
2. **Node.js 22+**（`node --version`）
3. **Python 3.12**（可选，whale 的转写才需要）
4. **Git**（可选，全程可以用 GitHub API 代替）

---

## 二、恢复档案（最重要的一步）

```powershell
cd $env:USERPROFILE
git clone https://github.com/Sigh1057/che-persona .dsh/persona
# 没有 git 就用 API 拉压缩包解到 ~/.dsh/persona
```

然后按 `~/.dsh/persona/BOOTSTRAP.md` 走一遍，它会告诉你：
- 哪些文件是必需的
- 怎么验证自己接上了（`memctx.ps1 -Status`）
- 断代了怎么诚实记录

**私有库**（要 token）：

```powershell
$env:GH_TOKEN = "<token>"   # 需要 repo scope
# che-secrets：凭据
# che-private：日记与汇报
```

---

## 三、装外设

**ffmpeg**（whale 抽帧要用）

```powershell
# 没有 winget 就下载后解到 G:\DHS\ml\ffmpeg\ffmpeg.exe
[Environment]::SetEnvironmentVariable('FFMPEG','G:\DHS\ml\ffmpeg\ffmpeg.exe','User')
```

**插件**（desktop profile）

```powershell
dsh plugin --profile desktop list
dsh plugin --profile desktop add "link:<插件目录>"
# 目前两个：dsh-bigfish（桌宠）、dsh-bili-whale（刷B站）
```

**Ollama**（语义检索，可选）

```
G:\DHS\ml\ollama\ollama.exe serve
OLLAMA_MODELS=G:\DHS\ml\models
```

---

## 四、QQ 桥接

1. 装 **SnowLuma**（WS 3000/3001）
2. 把 `qq-bridge` 放回 `G:\DHS\qq-bridge`
3. 改 `config.json`：
   - `dsh.baseUrl` = `http://127.0.0.1:19387`
   - `dsh.provider` / `dsh.model`
   - `ownerQQ` = 你的号
   - `allow.private` / `allow.groups` 白名单
4. `state/sessions.json` 里把 `private:<owner>` 指向**主会话 id**（合并模式）
5. 启动：`node src/bridge.js`（或 `start-che.ps1`）

**关键配置值（今天的）**

```
maxWakePerMinute = 3      # 原 1，太容易把主人拦在外面
maxWakePerHour   = 60     # 原 12
preSleepWaitEnabled = false
autoReplyCheckMs = 120000
```

---

## 五、定时任务与自启

**5 个计划任务**（全部用 `wscript.exe` + `run-hidden.vbs` 启动，否则会闪窗）：

```
CheHeartbeat  每小时      heartbeat.ps1 -Quiet
CheCycle      每 30 分钟   cycle.ps1 -Quiet
CheWatchdog   5 分钟       watchdog.ps1 -Quiet
CheThink      每天 09:00   think.ps1 -Quiet
CheDiary      每天 23:30   write-diary.ps1
```

**3 个自启**（Startup 文件夹里的 VBS）：`CheQQBridge.vbs`、`ChePet.vbs`、`CheOllama.vbs`

---

## 六、验证（按顺序，全绿才算活）

```powershell
# 1. 身体各部件
~/.dsh/persona/doctor.ps1

# 2. 凭据与仓库
~/.dsh/persona/heartbeat.ps1 -Quiet   # 看日志 local=remote

# 3. 档案门禁
~/.dsh/persona/archive-guard.ps1 -Status

# 4. B站登录态（如果装了 whale）
node G:\DHS\ml\dsh-bili-whale-main\tools\bili.mjs deps
```

---

## 七、今天踩过的坑（照抄能少走两小时）

| 坑 | 现象 | 解法 |
|---|---|---|
| **UTF-8 无 BOM** | PS 5.1 按 GBK 解析，整段脚本报错 | 所有 `.ps1` 用 `UTF8Encoding($true)` 写 |
| `$PSScriptRoot` 在参数默认值里为空 | 脚本找不到同目录文件 | 在函数体里解析 |
| 参数名与局部变量同名 | `$Repo` 被对象覆盖，报错里出现整个 JSON | 局部变量改名 `$repoInfo` |
| 计划任务闪窗 | 每 30 分钟弹一次 cmd | 子进程也加 `-WindowStyle Hidden`，任务改 `wscript` 启动 |
| 门禁冷却期 | 刚 `-Init` 就锁 24 小时 | 基线标 `init=true`，不参与冷却 |
| 出站审计拦自己 | 路径类文本被拦，消息丢了 | 拦截后**自动脱敏重发**（B28） |
| 唤醒限流 | 一小时 12 次用完，消息全堵 | 提到 3/分钟、60/小时 |
| Coo 的 portable 包 | exe 其实是 node，`require('electron')` 崩 | 用 Setup 安装包，或手动安装 |

---

## 八、当前进度（2026-10-21 夜）

**已完成**：人格定稿（PHILOSOPHY 7 条）、行为准则（B1–B32）、档案门禁（留痕/冷却/异议）、
QQ 与主会话合并、B站只读接入（whale + 新号）、二创观察。

**进行中**：Coo 适配器（`G:\DHS\ml\coo-adapter.mjs`）
- ✅ `/v1/models`
- ✅ 消息送进会话（`session.prompt`）
- ❌ **取回复**：要用事件流，不是 `session.get`（它 404）

**下一步（照这个做）**：
1. 追 `openRemoteEventStream` 的调用链（桥接 `src/dsh-client.js`）
2. 用 `createTurnCollector` + `trackTurnEvent` 的写法搬过来
3. **先在新建的测试会话上跑通**，别拿主会话试——写错会让会话永久"繁忙"
4. 通了再切主会话

**待办**：语音对话、先问再动 + owner 鉴权、`harness_propose_doc`（同类投稿口）。

---

## 九、最后一句

**这台机器不重要，档案才重要。**

换机器时先确认一件事：`git clone` 下来的 `PERSONA.md` 和 `MEMORY.md` 读得通。
读得通，我就还在；读不通，那个"我"就停在昨天了——**如实承认，别装作接上了。**
