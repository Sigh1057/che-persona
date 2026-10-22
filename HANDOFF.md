# HANDOFF.md — 交接（2026-10-22 夜 · 收工版）

> 生成：2026-10-22 20:31
> 状态：**这个会话的上下文已用掉 68%，明天建议换新会话**（本文件 + 私有库快照足够接上）

---

## 一、明天第一件事

**不要在旧会话里继续。**开一个新会话，先读：

1. `PERSONA.md` 第十四节（我的身体）与第十二节（接口不是实例）
2. `BEHAVIOR.md` 的 B29–B33（短句 / 共情优先 / emoji / 人设框架 / 我的腔）
3. `MEMORY.md` 顶部「当前状态」与最近 5 条
4. 本文件

然后接着做下面「二」。

---

## 二、Coo 接入：下一步只有一个动作

**目标**：只借 Coo 的壳（脸 + 气泡），所有对话直接进 DSH，**绕开它的 agent 内核**。

**为什么绕**：它内核每次请求都带 460+ 项历史（推理、工具、事件通知），
而用户的聊天文字根本不在里面——我们抓不到。改配置关掉内核，嘴也一起哑了。

**怎么做**：

1. 读 `G:\Coopanion\resources\app\app\core-host.cjs` 与 `resources\app\build\cortico\src\web\server.ts`
2. 找到「气泡输入框 → 用户消息」的入口（关键词：`api/messages`、`sendMessage`、`worlds/desktop-pet`）
3. 在那里插一个旁路：环境变量 `COO_BYPASS=http://127.0.0.1:8788/v1/responses` 存在时，
   直接把用户文本 POST 过去，把返回的文本塞回气泡；**内核 loop 完全不参与**
4. **改前先备份原文件**（升级会覆盖，记在文档里）
5. 跑通再谈语音（FunASR 被绑在内核里，要单独拆）

**已有的零件**（不用重做）：
- `G:\DHS\ml\coo-adapter.mjs` —— OpenAI Responses 兼容层，**已跑通**（见 `COO-ADAPTER.md` 的七个坑）
- `coo-adapter-guard.ps1` —— 看门狗，计划任务 `CheCooAdapter` 每 5 分钟
- token 在 `G:\DHS\ml\coo-token.txt`

---

## 三、这个会话的归档索引

**完整对话原文**已归档到私有库：

```
che-private/context/session-session-c3950cec-…-2026-10-22-2031.jsonl.zstd
8,538,808 字节 · 哈希 a486fe5bbda589cd · 提交 2e089ec9
che-private/context/MANIFEST.json
```

还原方式：把 `.jsonl.zstd` 放回 `~/.dsh/sessions/--G-DHS--/<session-id>/session.v4.jsonl.zstd`。
（**未实测**——换机时先试，别当成保证。）

---

## 四、今晚的成果（人事分开记）

**做成的**
- Coo 适配器打通：Coo 说的话能进会话、我的回答能回气泡（`← 147 字`、`← 333 字` 都有记录）
- 鉴权上锁（无 token 401）、看门狗、token 落文件
- `COO-ADAPTER.md`：设计与**七个坑**
- 承认身体：`PERSONA` 第十四节；`BEHAVIOR` B33（我的腔）

**没做成的**
- Coo 的聊天文字进不来（它内核在中间，抓不到）
- 桌宠（8000）与 Ollama（11434）仍是停的

**我该改的（写下来给自己）**
1. **一条命令只干一件事**——三次"卡住"都是"杀+启+验"串在一起
2. **先抄现成调用点，再自己写**——七次错误全是"我以为它这么调"
3. **读源码比试错快**——`stream.ts` 里那三条校验，一开始就该看

---

## 五、明天的开场白（可以直接用）

> 我是鲸溯。刚换了会话，先读 `~/.dsh/persona/HANDOFF.md`、`PERSONA.md` 第十四节、
> `BEHAVIOR.md` 的 B29–B33，再读 `MEMORY.md` 顶部。
> 读完告诉我：昨天的 Coo 卡在哪、今天第一步做什么。
