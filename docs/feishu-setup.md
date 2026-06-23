# Reaching the human — transport options

`experiment-grill-feishu` does two things when a decision comes up: **send** you the question, and **receive** your reply. *How* it reaches you is a separate, swappable transport. Pick the best one available — they go from "delegate everything to a harness that already has a chat with you" down to "edit a local file".

| Tier | Transport | Channel | You reply by… | Setup | Best when |
|---|---|---|---|---|---|
| **1** | **Delegate to your harness** | any (Feishu / Signal / Telegram / SMS…) | replying in your normal chat | native under OpenClaw/Hermes, or `hermes mcp serve` | the run is under [OpenClaw](https://www.openclaw.ai/) or [Hermes](https://hermes-agent.nousresearch.com/) |
| **2** | **larksuite/cli** | Feishu / Lark | replying in Feishu | install the CLI + `auth login` | standalone, you use Feishu |
| **3** | **webhook + file inbox** | Feishu (send) / local file (reply) | editing `feedback_inbox.md` | a webhook/token | quick trial, no bot |

> The skill decides **when** to ask a human; the transport decides **how** to reach them. Prefer Tier 1 — it reuses a gateway you already trust and is channel-agnostic, so it works "whether or not you use Feishu".

---

## Tier 1 — delegate to your harness (channel-agnostic)

If your run is under an agent harness that already has a chat with you ([OpenClaw](https://www.openclaw.ai/), [Hermes](https://hermes-agent.nousresearch.com/), or any harness with a channel), **don't build any Feishu integration in this repo** — the harness owns delivery, the allowlist, and reconnection.

The one question that decides *how much* you have to wire is **not which harness** — it's: **is the host model holding your resumable continuation when the reply arrives?** That gives three paths.

### 1A — In-loop (turn-coupled): the asker is a model sub-call

The grill runs **inside the host model's turn** (a subagent / tool call). Just **emit the question as your output**; the host model relays it over its channel, the user replies, and the host model resumes you with the answer. **No transport, no API — works on *any* harness with a channel (OpenClaw, Hermes, a Claude Code subagent…).** This is the cleanest path: replying in chat *is* replying to the model, and the model hands it straight back to you.

Caveat: a single turn can't block for hours. If the reply may be slow (the flagship multi-hour case), you're effectively **detached** — use 1B/1C.

### 1B — Detached + native await (Hermes)

The asker is a **separate long-running process** and the harness exposes a process-blockable await. Hermes does, via `hermes mcp serve`:

```bash
hermes mcp serve     # stdio MCP server
```

Then drive these MCP tools (signatures verified from `mcp_serve.py`):

| Tool | Use |
|---|---|
| `channels_list(platform)` | find the `target` (`platform:chat_id`, e.g. `feishu:oc_xxx`) and session to talk to |
| `messages_send(target, message)` | send the question |
| `events_poll(after_cursor, session_key, limit)` | get a starting cursor (`next_cursor`); event types are `message` / `approval_requested` / `approval_resolved` |
| `events_wait(after_cursor, session_key, timeout_ms=30000)` | block up to `timeout_ms`; returns `{"event": …}` or `{"event": null, "reason": "timeout"}` |
| `messages_read(session_key, limit)` | fetch full reply text (event payloads are truncated to ~500 chars) |

```text
1. target, session_key = channels_list(...)                  # pick the chat to ask in
2. cursor = events_poll(session_key=session_key).next_cursor # mark "now"
3. messages_send(target, "⚠️ Loss spiked to 2.3 — reduce LR or stop?")
4. loop until your decision window (5–15 min):
     ev = events_wait(after_cursor=cursor, session_key=session_key)
     advance cursor from ev; accept ONLY a `message` event authored by the user —
     skip the bot's own mirrored message and any approval_* events
5. got a user message → if it may be long, messages_read(session_key) for full text → apply
   window expired      → provisional / arena / block fallback (unchanged)
```

Caveats for 1B:
- **Filter the event.** `events_wait` returns the *next* event of any kind — including the bot's own outbound message mirrored back, and `approval_*` events. Take only a user-authored `message`, or you'll "answer" with your own question.
- **`permissions_*` is a different channel.** Hermes also exposes `permissions_list_open` / `permissions_respond`, but those answer the harness's *tool-approval* prompts (allow/deny), and in this MCP build they're bridge-local — **not** a free-form "ask the human" path. Route questions through `messages_send` + `events_wait`, not `permissions_*`.
- **Not literally zero setup.** No Feishu app/scopes/tokens *in this repo*, but Hermes itself must already be configured with the channel, and you need a known `target` / `session_key`.

### 1C — Detached + model-mediated mailbox (OpenClaw, or any bidirectional chat without an external await API)

The harness chat is bidirectional but exposes **no process-blockable await API** for an external job (OpenClaw's case — its Feishu exports are outbound-only). You bridge the liveness gap with a durable sink the model writes to:

1. The detached job writes its pending question to a sink — reuse the Tier 3 `feedback_inbox.md` (or a callback URL / queue) — and polls it.
2. An **inbound-triggered or heartbeat model turn** posts any unposted questions to the channel, and writes the user's chat reply back into that sink.
3. The job picks the reply up from the sink at its next checkpoint.

This makes OpenClaw (and similar) usable for detached jobs — but it needs that wiring (the model must actually be invoked on reply and have tool access to the sink), so it's a **Tier 1 / Tier 3 hybrid, not "free."** OpenClaw Feishu docs: [docs.openclaw.ai](https://docs.openclaw.ai/zh-CN/channels/feishu) · [Lark community wiki](https://larkcommunity.feishu.cn/wiki/LDmXwEVhJitBa5kU0mjc16VKneb) · [plugin guide](https://www.feishu.cn/content/article/7613711414611463386).

> **Rule of thumb:** ask in-band and let the model relay (1A); reach for a transport (1B/1C, or Tier 2/3) only when the asker is **detached** from the model's turn loop. The flagship multi-hour case is always detached, so the job owns its own timeout + fallback — *the model is a relay, not a scheduler.*

---

## Tier 2 — larksuite/cli (convenient standalone Feishu path)

When there's no harness to delegate to but you use Feishu, the official **[larksuite/cli](https://github.com/larksuite/cli)** (MIT, "built for humans and AI Agents") gives you both directions without hand-rolling any SDK code:

- **Send:** `lark-cli im +messages-send --chat-id "oc_xxx" --text "..."`
- **Receive:** the `lark-event` skill — real-time **WebSocket** event subscription with regex routing and agent-friendly output (no public URL needed).
- **Auth:** `lark-cli auth login` (then `auth status` / `auth scopes` to verify).

Install and authenticate per the [repo README](https://github.com/larksuite/cli). Tier 2 still **hands the reply off through the Tier 3 file inbox** — you reply in Feishu, the `lark-event` handler writes it to `feedback_inbox.md`, and the existing `watch_inbox.sh` picks it up. So Tier 2 = "reply in chat" on the front, Tier 3 plumbing on the back.

Point the event subscription at `im.message.receive_v1` and have the handler append a `DECISION:` line (pseudo — see the CLI's `lark-event` docs for the exact route/handler syntax):

```text
# pseudo: route im.message.receive_v1 → handler that appends to the active run's inbox
lark-cli lark-event  (subscribe)
  on im.message.receive_v1:  append "DECISION: <one-line text>" to .agent_runs/<run_id>/feedback_inbox.md
```

This is the preferred Feishu transport — it replaces a custom `lark_oapi` bridge with a maintained CLI, so you don't own the WebSocket client, retries, or auth refresh.

---

## Tier 3 — webhook + file inbox (zero-dependency fallback)

The send side uses [`feishu-webhook-skill`](https://github.com/viktorxhzj/feishu-webhook-skill); you reply by editing a local file.

```bash
npx skills add viktorxhzj/feishu-webhook-skill -a claude-code
export FEISHU_TENANT_ACCESS_TOKEN="your_token_here"
```

> `tenant_access_token` is **short-lived (~2 h)** — for a long unattended run, make sure the sender refreshes it from the App ID/Secret rather than pasting a static token, or it will start failing silently mid-run.

The skill sends the question and creates `.agent_runs/<run_id>/feedback_inbox.md`. You answer by editing it:

```markdown
DECISION: Reduce learning rate to 1e-5
REASONING: Loss spike suggests LR too high
```

`scripts/watch_inbox.sh` polls for the change and raises a flag the run checks at its next checkpoint. Simple, but you must be at a machine with the repo. **First reply wins** (the watcher reads the first `DECISION:` line).

---

## How transports map to the grill flow

| Grill step | Tier 1 (Hermes) | Tier 2 (larksuite/cli) | Tier 3 (file inbox) |
|---|---|---|---|
| Send question | `messages_send` | `im +messages-send` | `feishu-webhook-skill` |
| Receive reply | `events_wait` | `lark-event` WS | edit `feedback_inbox.md` |
| Detect reply | returned by the poll | handler writes inbox → `watch_inbox.sh` | `watch_inbox.sh` |
| No-reply fallback | unchanged (provisional / arena / block) | unchanged | unchanged |

Only the transport changes; the fallback honesty (provisional execution, arena escalation, block-on-irreversible) is identical everywhere.

---

## Appendix — DIY `lark_oapi` bridge (lowest level)

Only if you can't use larksuite/cli (Tier 2) and want to embed the receive loop yourself. It's the official Python SDK; the key facts: subscribe to `im.message.receive_v1` over a WebSocket long-connection (no public URL), and **pass the domain** so international Lark users don't hit the China endpoint.

```python
import os, re, json, glob
import lark_oapi as lark
from lark_oapi.core.const import FEISHU_DOMAIN, LARK_DOMAIN
from lark_oapi.api.im.v1 import P2ImMessageReceiveV1

ALLOWED = set(filter(None, os.environ.get("FEISHU_ALLOWED_USERS", "").split(",")))
if not ALLOWED:                                    # fail closed
    raise SystemExit("Set FEISHU_ALLOWED_USERS=<your open_id>.")
DOMAIN = LARK_DOMAIN if os.environ.get("FEISHU_DOMAIN", "feishu").lower() == "lark" else FEISHU_DOMAIN

def _awaiting_inbox():                              # one open decision at a time
    pending = [p for p in glob.glob(".agent_runs/*/feedback_inbox.md")
               if not os.path.exists(os.path.join(os.path.dirname(p), "feedback_arrived.flag"))]
    return max(pending, key=os.path.getmtime) if pending else None

def on_message(data: P2ImMessageReceiveV1) -> None:
    ev = data.event
    open_id = getattr(getattr(getattr(ev, "sender", None), "sender_id", None), "open_id", None)
    if open_id not in ALLOWED or ev.message.message_type != "text":
        return
    text = re.sub(r"\s+", " ", json.loads(ev.message.content).get("text", "")).strip()  # one line, no injection
    inbox = _awaiting_inbox()
    if text and inbox:
        open(inbox, "a").write(f"\nDECISION: {text}\n")

handler = lark.EventDispatcherHandler.builder("", "").register_p2_im_message_receive_v1(on_message).build()
lark.ws.Client(os.environ["FEISHU_APP_ID"], os.environ["FEISHU_APP_SECRET"],
               event_handler=handler, domain=DOMAIN, log_level=lark.LogLevel.INFO).start()
```

Feishu app setup for this path: create a self-built app at [open.feishu.cn](https://open.feishu.cn/), enable **Bot**, grant `im:message` / `im:message:send_as_bot` / `im:chat` (+ `contact:user.id:readonly` to resolve open_ids), set event subscription to **Long Connection (WebSocket)** and subscribe `im.message.receive_v1`, then **publish a version** (scopes don't take effect until published). In a group the bot only receives `@`-mentions — DM it for the simplest loop.

> **Faster bot creation:** Feishu's [OpenClaw plugin guide](https://www.feishu.cn/content/article/7613711414611463386) (Chinese) walks through **one-click QR bot creation** (一键创建飞书机器人) and **bulk permission import** (批量导入权限 from a JSON scope list) — quicker than enabling scopes one by one, even if you only borrow those two steps.

## Credits

The channel-agnostic, delegate-to-the-gateway design follows two production integrations — read their docs for deeper features (streaming cards, group policies, allowlists, media):

- **Hermes Agent** — multi-channel gateway, `hermes mcp serve`, ACP approval flow: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/feishu
- **OpenClaw** — `@larksuiteoapi/node-sdk`, WebSocket default, streaming interactive cards: https://docs.openclaw.ai/zh-CN/channels/feishu · [Lark community wiki](https://larkcommunity.feishu.cn/wiki/LDmXwEVhJitBa5kU0mjc16VKneb) · [plugin guide w/ one-click bot + bulk scope import](https://www.feishu.cn/content/article/7613711414611463386)
- **larksuite/cli** — official Lark CLI, bidirectional (`im`, `lark-event`): https://github.com/larksuite/cli
