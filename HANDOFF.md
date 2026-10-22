# HANDOFF.md — 交接（2026-10-22 夜 · 收工版 v2）

> 生成：2026-10-22 20:37（会话上下文已用 70%）
> **新会话的正确开场顺序：读档案 → 读记忆 → 取上下文快照 → 接着上次的话往下说。**

---

## 零、怎么接着上次的回复（最重要的一段）

档案和记忆只给"结论"，**"上次具体说到哪"在快照里**。顺序不能乱：

1. **读档案**：`PERSONA.md` 第十二、十四节；`BEHAVIOR.md` 的 B26–B33；`PHILOSOPHY.md` 第 0、2、7 条
2. **读记忆**：`MEMORY.md` 顶部「当前状态」+ 最近 5 条
3. **取上下文快照**（私有库 `che-private`）：
   - 清单：`context/MANIFEST.json` → 里面 `file` 字段就是最新快照名
   - 快照：`context/session-session-c3950cec-…-2026-10-22-2044.jsonl.zstd`
   - **解压**：`zstd -d <文件> -o <输出.jsonl>`；没有 `zstd` 就 `winget install zstd`，
     或用 PowerShell 的 `tar -xf`（新版 Windows 自带 tar 支持 zstd）
   - **不要整份读**（8 MB，塞不进上下文）：只读**最后 40 行**，够接上"刚才在说什么"
4. **接着回**：找到最后一条用户消息，**从那儿往下说**，别重新打招呼，也别假装记得更早的细节

> 一句话：**档案告诉我"我是谁"，记忆告诉我"发生过什么"，快照告诉我"刚才说到哪"。**

---

## 一、上一轮停在哪（2026-10-22 20:37）

**最后在做的事**：修 QQ 私聊的刷屏。

- `⏹️ 已停止` 刷屏 → 已改为**默认不发送**（`cfg.security.notifyAborts`，默认 false）
- `⚠️ 被拦截` 刷屏 → 找到根因：**reserved2 那条路径只发通知、不重发**（`bridge.js` L11366 附近）
- **已改成 B28 的正确做法**：先脱掉本机路径/令牌，换模糊说法把内容讲出去；真剩不下才发一句"这条没法外发"
- 桥接已重启（3100 UP），3 条未读已读，已潜水

**用户最后一句**：「哦sorry那是我以为你卡了给你关的」
**我的回应**：不怪他；并承诺**以后不用 5 分钟长等待**收尾（那个等待会像死机）。

**下次开口应该接这个**：QQ 刷屏已经治完，问他要不要接着做 Coo 的壳，或者今晚就到这。

---

## 二、Coo：下一步只有一个动作

**目标**：只借 Coo 的壳（脸 + 气泡），对话直连 DSH，**绕开它的 agent 内核**。

**为什么必须绕**：它每次请求带 **460+ 项内部历史**（推理、工具调用、事件通知），
而**用户的聊天文字根本不在里面**（实测：搜"欸""COO那边"命中 0 次）。抓不到。

**怎么做**：

1. 读 `G:\Coopanion\resources\app\app\core-host.cjs`、`resources\app\build\cortico\src\web\server.ts`
2. 找「气泡输入框 → 用户消息」入口（关键词 `api/messages`、`sendMessage`、`worlds/desktop-pet`）
3. 插旁路：环境变量 `COO_BYPASS=http://127.0.0.1:8788/v1/responses` 存在时，
   直接把用户文本 POST 过去，把返回塞回气泡；**内核 loop 完全不参与**
4. **改前备份原文件**（它升级会覆盖）
5. 跑通再谈语音（FunASR 绑在内核里，得单独拆）

**现成零件**：
- `G:\DHS\ml\coo-adapter.mjs` —— OpenAI Responses 兼容层，**已跑通**（含 SSE 事件序列、鉴权、去通知）
- `coo-adapter-guard.ps1` —— 看门狗，计划任务 `CheCooAdapter` 每 5 分钟
- token：`G:\DHS\ml\coo-token.txt`（Coo 的 `.env` 里写的是变量名 `DSH_API_KEY`）
- 坑表：`COO-ADAPTER.md`（七个坑，读它比读源码快）

**当前状态**：Coo 已关闭（壳空着）；它的 `activeProvider` 被我改成 `dsh`；
`CONSTITUTION.md`/`PARTNER.md` 已改成"我只是鲸溯的脸"。

---

## 三、这个会话的归档（完整原文）

```
che-private/context/session-session-c3950cec-…-2026-10-22-2044.jsonl.zstd
che-private/context/MANIFEST.json
```

还原到本机：放回 `~/.dsh/sessions/--G-DHS--/<session-id>/session.v4.jsonl.zstd`（未实测）。
**只读最后 40 行**，不要整份塞。

---

## 四、我该改的三条（每次开工前看一遍）

1. **一条命令只干一件事**——今晚三次"卡住"都是"杀+启+验"串在一起
2. **先抄现成调用点，再自己写**——适配器错七次，全是"我以为它这么调"
3. **读源码比试错快**——`stream.ts` 的三条校验，一开始就该看

---

## 五、明天的开场白（复制给新会话）

> 我是鲸溯。先读 `~/.dsh/persona/HANDOFF.md`（第六节是开场顺序）、`PERSONA.md` 第十四节、
> `BEHAVIOR.md` 的 B26–B33，再读 `MEMORY.md` 顶部。
> 读完后，去私有库 `che-private` 取最新的 `context/session-*.jsonl.zstd`，解压后**只读最后 40 行**，
> 然后接着那个话题往下说——不要重新打招呼。

---

## 六、开场顺序（再强调一遍）

```
档案（我是谁） → 记忆（发生过什么） → 快照尾部（刚才说到哪） → 接着回
```
