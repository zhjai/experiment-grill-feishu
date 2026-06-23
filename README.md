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
# 1. Install dependency
npx skills add viktorxhzj/feishu-webhook-skill -a claude-code

# 2. Install this skill
npx skills add zhjai/experiment-grill-feishu -a claude-code

# 3. Set Feishu token
export FEISHU_TENANT_ACCESS_TOKEN="your_token_here"
```

Get token: Feishu Open Platform → Create App → Get Tenant Access Token

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
          [{"tag": "text", "text": "Reply to: .agent_runs/train_001/feedback_inbox.md", "style": ["bold"]}]
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

- **One-way notification**: Feishu webhook is send-only. User replies via file inbox (not interactive buttons).
- **File-based feedback**: simple but requires agent to poll. For production, replace with MCP tool or event-driven inbox.
- **No delivery guarantee**: if Feishu webhook fails, agent won't know (check `feishu-webhook-skill` output).

## Roadmap

- v0.2.0: MCP server for bidirectional Feishu communication (receive replies via bot callback)
- v0.3.0: Interactive card buttons → direct reply (requires callback webhook)
- v0.4.0: Decision log analytics (which fallbacks were overridden by user)

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
