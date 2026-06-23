# Feishu setup — two integration modes

`experiment-grill-feishu` needs to do two things over Feishu (飞书 / Lark):

1. **Send** you the question when a decision comes up.
2. **Receive** your reply (so the run can apply it).

There are two ways to wire this, trading setup effort for UX. Pick one.

| | **Mode A — webhook + file inbox** | **Mode B — bidirectional bot** *(recommended)* |
|---|---|---|
| Setup effort | Minimal (a webhook URL or tenant token) | Create a Feishu app, grant scopes, publish |
| You reply by… | **editing a local file** (`feedback_inbox.md`) | **replying in the Feishu chat** |
| Public endpoint needed | No | No (uses an outbound WebSocket long-connection) |
| Best for | quick trials, single machine | real unattended runs where you only have your phone |

Mode B is how mature agents wire Feishu — see **OpenClaw** ([docs](https://docs.openclaw.ai/zh-CN/channels/feishu)) and **Hermes** ([docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/feishu)). Both default to the **long-connection (WebSocket) event subscription**, which is why neither needs a public callback URL. This tutorial follows the same approach.

---

## Mode A — webhook + file inbox (quick)

The send side uses [`feishu-webhook-skill`](https://github.com/viktorxhzj/feishu-webhook-skill); the reply side is a local file you edit.

```bash
npx skills add viktorxhzj/feishu-webhook-skill -a claude-code
export FEISHU_TENANT_ACCESS_TOKEN="your_token_here"
```

> `tenant_access_token` is **short-lived (~2 h)**. For a long unattended run, a fixed exported token will start failing silently mid-experiment — make sure your sender refreshes it from the App ID/Secret (the webhook skill / Mode B app credentials do this for you), rather than pasting a static token.

When a decision arises, the skill sends the question to Feishu and creates `.agent_runs/<run_id>/feedback_inbox.md`. You reply by editing that file:

```markdown
DECISION: Reduce learning rate to 1e-5
REASONING: Loss spike suggests LR too high
```

`scripts/watch_inbox.sh` polls for the change and raises a flag the run checks at its next checkpoint. Simple, but you must be at a machine with the repo to answer.

---

## Mode B — bidirectional bot (recommended)

Here the bot **receives your reply right in the Feishu chat**. The send side can stay on `feishu-webhook-skill` (or use the same app's `im.message.create` API); the new piece is a small **receive bridge** that listens over a WebSocket long-connection and writes your reply into the same `feedback_inbox.md` — so the rest of the grill flow is unchanged.

### 1. Create a self-built app

Open the Feishu Open Platform — [open.feishu.cn](https://open.feishu.cn/) (China) or [open.larksuite.com](https://open.larksuite.com/) (international) — and create a **self-built app** (自建应用). Copy the **App ID** (`cli_xxx`) and **App Secret** from **凭证与基础信息 / Credentials & Basic Info**.

### 2. Enable the Bot capability

Under **应用能力 / Add features → 机器人 / Bot**, enable the bot. (Interactive-card buttons additionally need *Interactive Card* turned on here — optional; plain replies don't.)

### 3. Grant permission scopes

Under **权限管理 / Permissions**, add at minimum:

| Scope | Why |
|---|---|
| `im:message` | receive and read messages |
| `im:message:send_as_bot` | send messages as the bot |
| `im:chat` / `im:chat:readonly` | read chat / group metadata |
| `im:resource` | (optional) images, files, audio |
| `contact:user.id:readonly` | (optional) resolve a replier's `open_id` for the allowlist |

This is a set similar to what OpenClaw and Hermes request (see Credits) — start here and add more only if the console reports a missing scope.

> **Group chats:** in a group, the bot only receives a message when it is **@-mentioned**. For the simplest grill loop, **DM the bot directly** — then every message reaches the bridge.

### 4. Configure event subscription — choose Long Connection

Under **事件订阅 / Event Subscription**:

- Set the delivery mode to **长连接 / Long Connection (WebSocket)**. This is the important choice — with long-connection the bot dials *out*, so **you need no public URL, no reverse proxy, no HTTPS cert**.
- Subscribe to the event **`im.message.receive_v1`** (接收消息). This is the only event needed to get replies.

> Webhook alternative: if you'd rather run an HTTP server (e.g. you're already behind a reachable endpoint), pick webhook mode instead and set a **Verification Token** (and optional **Encrypt Key**). WebSocket is simpler for unattended runs and is the default in both reference implementations.

### 5. Publish a version

Go to **版本管理与发布 / Version Management & Release** and publish a version. **Scopes and events do not take effect until a version is published and approved** — this is the most common "why isn't it working" cause.

### 6. Set credentials

```bash
export FEISHU_APP_ID="cli_xxx"
export FEISHU_APP_SECRET="xxx"
export FEISHU_DOMAIN="feishu"             # 'feishu' (China) or 'lark' (international)
# REQUIRED for safety: only these open_ids may steer a run (the bridge fails closed without it)
export FEISHU_ALLOWED_USERS="ou_xxx"      # your open_id — see below
```

To find your `open_id`: start the bridge below with an empty allowlist removed, DM the bot once, and the bridge log prints the sender's `open_id` (the bridge below logs rejected senders); or use the Open Platform API explorer. The allowlist is **mandatory** — without it, anyone who can message the bot could write a decision into your live run.

### 7. Run the receive bridge

The bridge is a tiny long-running process built on the official Lark SDK (`lark_oapi`, the same SDK Hermes uses). It subscribes to `im.message.receive_v1` and writes whatever you send into the active run's inbox as a `DECISION:` line:

```python
# feishu_bridge.py — minimal bidirectional receive bridge (illustrative; adapt before production)
import os, re, json, glob
import lark_oapi as lark
from lark_oapi.core.const import FEISHU_DOMAIN, LARK_DOMAIN
from lark_oapi.api.im.v1 import P2ImMessageReceiveV1

# Fail closed: only these open_ids may steer a run. Empty allowlist = accept nobody.
ALLOWED = set(filter(None, os.environ.get("FEISHU_ALLOWED_USERS", "").split(",")))
if not ALLOWED:
    raise SystemExit("Set FEISHU_ALLOWED_USERS=<your open_id>. Refusing to accept replies from anyone.")

DOMAIN = LARK_DOMAIN if os.environ.get("FEISHU_DOMAIN", "feishu").lower() == "lark" else FEISHU_DOMAIN

def _awaiting_inbox():
    # the run still waiting for a reply = an inbox with no feedback_arrived.flag yet.
    # NOTE: assumes one open decision at a time. For concurrent runs, bind the reply to the
    # message/chat the question was sent in instead of guessing by mtime.
    pending = [p for p in glob.glob(".agent_runs/*/feedback_inbox.md")
               if not os.path.exists(os.path.join(os.path.dirname(p), "feedback_arrived.flag"))]
    return max(pending, key=os.path.getmtime) if pending else None

def on_message(data: P2ImMessageReceiveV1) -> None:
    ev = data.event
    sender = getattr(getattr(ev, "sender", None), "sender_id", None)
    open_id = getattr(sender, "open_id", None)
    if open_id not in ALLOWED:
        print(f"[bridge] ignored message from open_id={open_id!r} (not in allowlist)")
        return
    if ev.message.message_type != "text":          # post/image/etc. carry no plain text
        return
    raw = json.loads(ev.message.content).get("text", "")
    text = re.sub(r"\s+", " ", raw).strip()         # collapse to one line — blocks DECISION:/REASONING: injection
    inbox = _awaiting_inbox()
    if not text or not inbox:
        return
    with open(inbox, "a") as f:
        f.write(f"\nDECISION: {text}\n")
    print(f"[bridge] {inbox} <- {text!r}")

handler = (
    lark.EventDispatcherHandler.builder("", "")     # ("", "") = pure WebSocket: no encrypt/verify token needed
    .register_p2_im_message_receive_v1(on_message)
    .build()
)
client = lark.ws.Client(
    os.environ["FEISHU_APP_ID"], os.environ["FEISHU_APP_SECRET"],
    event_handler=handler, domain=DOMAIN, log_level=lark.LogLevel.INFO,
)
client.start()   # blocks; auto-reconnects
```

```bash
pip install lark-oapi
python feishu_bridge.py     # leave running alongside your experiment
```

Now the loop is fully async: the run sends a question to Feishu, you **DM the bot your answer from your phone**, the bridge drops it into `feedback_inbox.md`, and `watch_inbox.sh` / the run's checkpoint picks it up — the existing protocol, fed by the bot instead of by hand.

> **First reply wins.** `watch_inbox.sh` reads the *first* `DECISION:` line (`head -1`). Once you've answered, sending a correction won't override it — to change your mind, stop the run (or clear the inbox) and re-ask. A production bridge would key replies to the question's message id and consume the newest.

> **Sending stays separate.** The `lark.ws.Client` above is **receive-only**. Keep sending the outbound question through `feishu-webhook-skill`, or build a *separate* REST client — `lark.Client.builder().app_id(...).app_secret(...).domain(DOMAIN).build()`, then `client.im.v1.message.create(...)`. Either way, **send and receive must use the same self-built app** (and the bot must be in the chat you reply to), or the bridge never sees your reply.

---

## How it maps to the grill flow

| Grill step | Mode A | Mode B |
|---|---|---|
| Send question | `feishu-webhook-skill` | `feishu-webhook-skill` *or* `im.message.create` |
| Receive reply | you edit `feedback_inbox.md` | bridge writes it from your chat reply |
| Detect reply | `watch_inbox.sh` flag | same |
| No-reply fallback | unchanged (provisional / arena / block) | unchanged |

Mode B changes only the **receive** path, so the fallback honesty (provisional execution, arena escalation, block-on-irreversible) is identical.

## Credits

The bidirectional design here follows two production integrations — read their docs for deeper features (streaming cards, group policies, pairing/allowlists, media):

- **OpenClaw** — `@larksuiteoapi/node-sdk`, WebSocket default, streaming interactive cards: https://docs.openclaw.ai/zh-CN/channels/feishu
- **Hermes Agent** — `lark_oapi`, WebSocket default, allowlist + signature handling: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/feishu
