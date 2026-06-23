# experiment-grill-feishu

**Send Feishu notifications for critical experiment decisions, wait asynchronously for user reply, fall back to provisional execution or arena if no reply.**

## Problem

When running long experiments, training runs, or autonomous coding sessions, critical decisions arise:
- Learning rate ambiguous? Checkpoint corrupted? Accuracy dropped 20%?
- The agent needs human input, but **the human is probably not watching**.

Blocking and waiting wastes time. Proceeding blindly risks bad decisions.

## Solution

`experiment-grill-feishu` combines three existing patterns:
1. **grill-all**: question routing (human / docs / code / web) — only notify for human decisions
2. **feishu-webhook-skill**: Feishu message delivery
3. **human-interruptible-unattended-runner**: async fallback protocol

**Flow:**
1. Agent detects a critical decision
2. Check if docs/code/web can answer → if yes, use that (don't notify)
3. If human decision needed → send Feishu, create file inbox, wait 5–15 min
4. **User replies** → parse feedback, apply correction
5. **User doesn't reply** → execute provisional fallback:
   - Low-risk: proceed with recommended option (reversible, logged)
   - High-stakes: ask `agent-arena` for independent perspective
   - Irreversible: stop, save checkpoint, report blocker

## Install

```bash
npx skills add zhjai/experiment-grill-feishu -a claude-code
```

Then pick a **transport** for reaching you (next section). The quick-start below is the **Tier 3** path (webhook + file inbox):

```bash
# Tier 3 only: send via feishu-webhook-skill, reply via a local file
npx skills add viktorxhzj/feishu-webhook-skill -a claude-code
export FEISHU_TENANT_ACCESS_TOKEN="your_token_here"   # short-lived (~2h) — refresh for long runs
```

Get token: Feishu Open Platform → Create App → Get Tenant Access Token. (Tier 1/2 don't need this — see below.)

### How it reaches you — pick a transport ([`docs/feishu-setup.md`](docs/feishu-setup.md))

The skill decides **when** to ask a human; the transport decides **how** to reach you. Best-to-simplest:

| Tier | Transport | Channel | You reply by… | Best when |
|---|---|---|---|---|
| **1** | **Delegate to your harness** *(prefer if already under one)* | any (Feishu / Signal / Telegram / SMS…) | replying in your normal chat | the run is under [OpenClaw](https://www.openclaw.ai/) or [Hermes](https://hermes-agent.nousresearch.com/) |
| **2** | **[larksuite/cli](https://github.com/larksuite/cli)** | Feishu / Lark | replying in Feishu | standalone, you use Feishu |
| **3** | webhook + file inbox | Feishu / local file | editing `feedback_inbox.md` | quick trial, no bot |

**Tier 1 is channel-agnostic and needs no Feishu setup in this repo.** How much you wire depends on one thing — *is the host model holding your continuation when the reply lands?* — not on which harness:
- **In-loop** (the grill is a subagent / tool call): just ask as a normal message; the model relays the reply straight back. Nothing to build, works on **any** harness incl. OpenClaw. (Replying in chat *is* replying to the model.)
- **Detached** long-running job: Hermes offers a native await (`hermes mcp serve` → `messages_send` + `events_wait`); OpenClaw (no external await API) uses a small model-mediated mailbox — a heartbeat turn writes the chat reply into a file the job polls.

**Tier 2** uses the official Lark CLI (bidirectional: `im +messages-send` to send, `lark-event` WebSocket to receive) instead of a hand-rolled bridge; it relays the reply through the same file inbox as Tier 3.

> Running **natively** under OpenClaw, replies route back for you (its Feishu plugin is bidirectional). OpenClaw only lacks an *external* await-reply API, so a *standalone* grill under OpenClaw takes the reply via Tier 2/3. Docs: [docs.openclaw.ai](https://docs.openclaw.ai/zh-CN/channels/feishu) · [Lark community wiki](https://larkcommunity.feishu.cn/wiki/LDmXwEVhJitBa5kU0mjc16VKneb) · [plugin guide](https://www.feishu.cn/content/article/7613711414611463386).

Full setup for every tier is in **[`docs/feishu-setup.md`](docs/feishu-setup.md)**.

## Usage

### Quick start
```text
Use experiment-grill-feishu. For critical decisions, send Feishu notification and wait 5 min via file inbox. If I don't reply, use arena for high-stakes or proceed provisionally for low-risk. Apply my correction if I reply later.
```

### Example: Experiment training

```python
# Your training script
for epoch in range(20):
    loss = train_one_epoch()
    if loss > 2.0 and epoch > 5:
        # Agent detects anomaly, triggers experiment-grill-feishu
        # Sends Feishu: "Loss spiked to 2.3 at epoch 6. Stop or continue?"
        # Creates: .agent_runs/train_001/feedback_inbox.md
        # Waits 5 min...
        # No reply → asks arena → arena says "reduce LR to 1e-5"
        # Applies provisionally, continues
        pass
```

### User reply format

Edit `.agent_runs/<run_id>/feedback_inbox.md`:
```markdown
DECISION: Reduce learning rate to 1e-5
REASONING: Loss spike suggests LR too high
```

Agent parses `DECISION:` line and applies immediately at next checkpoint.

## Decision Classes

| Severity | Wait time | No-reply fallback |
|----------|-----------|-------------------|
| **Critical** (training failed, data corrupted) | 5 min | Arena → provisional (or stop if irreversible) |
| **Normal** (ambiguous config, unexpected result) | 15 min | Recommended option → provisional |
| **Low-risk** (retry strategy, logging fallback) | 0 min (auto-continue) | Proceed, log assumption |

## Feishu Message Example

The last line shows the **Tier 3** reply hint (edit the file). With Tier 1/2 it instead reads "Reply to this message" — you answer right in chat.

```json
{
  "msg_type": "post",
  "content": {
    "post": {
      "zh_cn": {
        "title": "⚠️ Experiment needs decision",
        "content": [
          [{"tag": "text", "text": "Question: Learning rate for fine-tuning?"}],
          [{"tag": "text", "text": "Context: ResNet CIFAR-10, batch=64, loss=0.8"}],
          [{"tag": "text", "text": "Options:\nA. 1e-4 (faster)\nB. 5e-5 (safer)"}],
          [{"tag": "text", "text": "Recommended: B\nFallback in 5min: Ask arena"}],
          [{"tag": "text", "text": "Reply in chat (Tier 1/2) — or edit .agent_runs/train_001/feedback_inbox.md (Tier 3)", "style": ["bold"]}]
        ]
      }
    }
  }
}
```

## What This Combines

- **grill-all**: source-aware question routing (only notify when human decision genuinely needed)
- **human-interruptible-unattended-runner**: async checkpoint protocol, provisional fallback honesty
- **feishu-webhook-skill**: Feishu message delivery
- **agent-arena**: independent perspective when user unavailable

## Limitations

- **Reply-in-chat needs a transport**: with Tier 3 you reply by editing the file inbox; **Tier 1/2** let you reply right in chat (Tier 2 still relays that into the inbox under the hood). See [`docs/feishu-setup.md`](docs/feishu-setup.md).
- **Inbox feedback is polled**: Tier 2/3 deliver the reply via `feedback_inbox.md`, which the run checks at checkpoints (`watch_inbox.sh`) — so a reply applies at the next safe checkpoint, not instantly. Tier 1 (Hermes `events_wait`) is the only push path.
- **No delivery guarantee**: if the send fails, the agent won't know unless it checks the send tool's output. Treat "no reply" as "not delivered or not seen" — the provisional/block fallback already does.

## Roadmap

- v0.2.0: first-class Tier 1 path — call Hermes `messages_send`/`events_wait` directly when running under Hermes
- v0.3.0: interactive card buttons → one-tap reply (subscribe `card.action.trigger`, enable Interactive Card)
- v0.4.0: decision log analytics (which fallbacks were overridden by the user)

## Status

`v0.1.0` preview. MIT. Requires `feishu-webhook-skill`, pairs with `grill-all`, `human-interruptible-unattended-runner`, `agent-arena`.

## Example Session

```text
User: Train ResNet on CIFAR-10. If anything looks wrong, notify me on Feishu.

Agent: [trains for 5 epochs]
       [detects loss spike: 0.5 → 2.3]
       [checks docs: no guidance]
       [checks code: no similar case]
       [triggers experiment-grill-feishu]
       [sends Feishu: "Loss spiked to 2.3 at epoch 6. Reduce LR or stop?"]
       [creates .agent_runs/train_001/feedback_inbox.md]
       [waits 5 min, polls every 30s]
       [no user reply]
       [fallback: asks agent-arena]
       [arena: "Reduce LR to 1e-5, monitor for 2 epochs"]
       [applies provisionally, continues]
       [epoch 7: loss back to 0.6]
       [final report: "Provisional decision: reduced LR (arena verdict). User did not reply. Training succeeded."]
```

## Further Reading

- [grill-all](https://github.com/zhjai/grill-all) — source-aware question routing
- [human-interruptible-unattended-runner](https://github.com/zhjai/human-interruptible-unattended-runner) — async fallback protocol
- [feishu-webhook-skill](https://github.com/viktorxhzj/feishu-webhook-skill) — Feishu message delivery
- [agent-arena](https://github.com/zhjai/agent-arena) — heterogeneous agent review
