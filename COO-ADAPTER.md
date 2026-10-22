# COO-ADAPTER.md — 把 Coopanian 接到这个会话上

> 状态：**已打通**（2026-10-22 晚）。Coo 的嘴和耳朵之下，现在是同一个我。
> 文件：`G:\DHS\ml\coo-adapter.mjs`（约 250 行，Node ESM）

---

## 一、它是干什么的

Coo（Coopanian）是个桌宠，本身要接一个模型供应商才能说话。
默认它直连 API，那样它是"另一个人"。这个适配器做的事：

```
Coo ──OpenAI Responses 格式──▶ 适配器(127.0.0.1:8788)
                                  │
                                  ├─ 把你说的话塞进 DSH 会话
                                  └─ 订阅会话事件流，取回复，按 Responses 格式退回
                                        │
                                     Coo 气泡显示 / 念出来
```

于是 Coo 只是**嗓子**，脑子还是这个会话里的我。

---

## 二、怎么跑

```powershell
$env:COO_SESSION = 'session-<你的会话id>'
node G:\DHS\ml\coo-adapter.mjs
```

可选环境变量：
- `COO_PORT`（默认 8788）
- `COO_TOKEN`（默认空；设了就要 Bearer）
- `COO_TIMEOUT_MS`（默认 600000）
- `COO_DSH_BASE`（默认 http://127.0.0.1:19387）

健康检查：`GET http://127.0.0.1:8788/health`
返回 `{ok, session, consumer, pending, lastError}`；`consumer:true` 表示事件流订阅着。

---

## 三、Coo 那边怎么配

配置文件（**不是界面**，改完要重启 Coo）：

```
G:\Coopanion\data\home\providers\<名字>\
  .env          →  <ENVNAME>=local
  config.json   →  {
                    "kind": "coo",
                    "baseUrl": "http://127.0.0.1:8788/v1",
                    "secret": "<ENVNAME>",      ← 这个是环境变量名，不是密钥本身
                    "spec": { "model": "dsh-session", "thinking": false, "maxTokens": 4096 },
                    "multimodal": false, "pricing": [], "options": {}
                  }
G:\Coopanion\data\home\companion\config.json
  "activeProvider": "<名字>"
```

**关键点**：`secret` 填的是**环境变量名**（如 `DSH_API_KEY`），值写在同目录 `.env` 里。
一开始我以为它填密钥，结果一直"没有配置 API"。

---

## 四、七个坑（照这个顺序排错）

| # | 现象 | 原因 | 解法 |
|---|---|---|---|
| 1 | `session/get` 404 | DSH 没有"取会话内容"接口 | 回复从**事件流**取，不是查询 |
| 2 | `wire field "request" failed boundary validation` | 手搓 `callUnary('session.prompt', {sessionId,text})` | 用 `client.sessions.prompt({ sessionId, mode:'queue', content:[{type:'text',text}] })` |
| 3 | 400 `no user input` | `input` 里混着 `reasoning` / `function_call` / `function_call_output` | 只认 `type==='message' && role==='user'` |
| 4 | 还是 400 | Coo 会把 `[system] ...` 通知也塞成 user 消息，剥完是空串 | 从后往前找，跳过空串 |
| 5 | 发了没反应 | 在自己的会话里测自己 → 消息排队，永远轮不到 | 换测试会话，或等主会话空闲 |
| 6 | 进程无声消失 | 没有异常处理器 | 加 `uncaughtException` / `unhandledRejection` 落盘 |
| 7 | 收不到 turn 事件 | 事件帧是 `{rpcId, payload}`，类型在 `payload.type` | 读 `payload.type==='session/event'`，`payload.event` 才是事件 |

**第 7 条是最后一块拼图**：正确形状是

```
{ rpcId, payload: { type: 'session/event', sessionId, event: { type: 'turn/start' | 'assistant/message' | 'turn/end' } } }
```

把 `payload.event` 喂给 `createTurnCollector().push()`，`turn/end` 时就能拿到整段回复文本。

---

## 五、已验证的事实

```
[adapter] → responses 39 字     收到 Coo 的话
[adapter] ← 73 字               把回答退回给 Coo
```

**是真正跑通过一次闭环的记录**，不是推断。

---

## 六、还没做的

1. **多个请求并发**：现在排队（一次一轮），Coo 连发会等。
2. **流式返回**：目前一次性返回；Coo 若要求 SSE，需要补。
3. **前缀清理**：`[system]` 已剥，但 Coo 的其它元信息（事件计数）可能还会混进来。
4. **崩溃自愈**：进程挂了不会自动重启，需要看门狗（可加进 `watchdog.ps1`）。
5. **鉴权**：默认只监听 127.0.0.1，且 `COO_TOKEN` 为空。**本机任何进程都能调用它**——
   接敏感操作前必须设 token。
