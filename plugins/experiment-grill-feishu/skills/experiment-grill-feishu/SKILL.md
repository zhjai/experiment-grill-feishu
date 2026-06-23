---
name: experiment-grill-feishu
description: 'Use when running experiments or long/unattended tasks where a critical or ambiguous decision needs human input but the human may not be watching. Asks the human over a configurable transport — preferring delegation to your agent harness (OpenClaw/Hermes, channel-agnostic), else the official larksuite/cli or a Feishu webhook + file inbox — waits asynchronously, applies the reply if it arrives, and falls back (provisional / agent-arena / block) if it does not. On first use it runs a soft init and remembers the transport, target, timing, and fallback policy in a project config so you do not re-choose each session. Combines grill-all question routing + human-interruptible-unattended-runner fallback protocol.'
version: 0.1.0
author: zhjai
license: MIT
metadata:
  tags: [ai-agents, experiment-tracking, feishu, lark, notification, async-feedback, human-in-the-loop, grill, arena]
  related_skills: [grill-all, human-interruptible-unattended-runner, feishu-webhook-skill, agent-arena]
---

# Experiment Grill (Feishu)

## Overview

Use this skill when running experiments, training runs, long evaluations, or autonomous coding sessions where critical issues or ambiguous decisions arise that ideally need human input — but the human may not be immediately available.

Core principle: **ask the human over your configured transport, wait asynchronously, execute provisional fallback if no reply, apply correction if reply arrives.**

This combines:
- **grill-all**: question routing (human / docs / code / web)
- **human-interruptible-unattended-runner**: async fallback protocol
- **a transport** to reach the human — harness delegation (preferred), larksuite/cli, or a Feishu webhook (chosen at init; see [`docs/feishu-setup.md`](../../../../docs/feishu-setup.md))

## Initialization (first use in a project) — soft init

On **first use in a project**, check whether `state/experiment-grill-feishu/config.yaml` exists. If it does, **read it and reuse the saved settings** — don't re-ask. If it doesn't, ask the user briefly, then write it (so every later run remembers the choice):

1. **Transport** *(always ask — no safe default)*
   "How should I reach you when a decision needs you?
   - **(1) your agent harness** *(default; `transport.tier: harness`, `harness: openclaw`)* — if you run under OpenClaw (or Hermes); channel-agnostic, no Feishu setup
   - **(2) Feishu via larksuite/cli** — official Lark CLI *(`larksuite`)*
   - **(3) Feishu webhook + file inbox** — simplest *(`webhook`)*"

2. **Target** *(needed unless Tier 1A in-loop, where the harness already knows the chat)*
   "Where should I send the question — a Feishu chat (`oc_xxx`), a user (`ou_xxx`), or a Hermes target (`feishu:oc_xxx`)? And which open_id(s) may answer?" → `target.type` + `target.id`, `target.allowed_users`. (The allowlist only applies to transports that authenticate the sender — Tier 1B event author, Tier 2, 1C; Tier 3's file inbox has no sender identity and trusts filesystem permissions.)

3. **Timing & fallback** *(don't ask — use defaults, mention they're editable)*
   Defaults: critical wait 5 min → arena, normal 15 min → provisional, irreversible → block. Tell the user these live in `config.yaml` and can be tuned.

Then write `state/experiment-grill-feishu/config.yaml` from the answers (see [`examples/config.example.yaml`](../../../../examples/config.example.yaml) for the full schema). **Secrets stay in env vars** (`FEISHU_APP_SECRET`, `FEISHU_TENANT_ACCESS_TOKEN`) — never write them into this file. Setup steps per transport are in [`docs/feishu-setup.md`](../../../../docs/feishu-setup.md).

## When to Use

Use for:
- experiment configuration ambiguities (learning rate? batch size?)
- critical failures during training (OOM? loss exploding? checkpoint corrupted?)
- unexpected results needing interpretation (accuracy dropped 20%?)
- architectural decisions mid-run (switch optimizer? add regularization?)
- irreversible actions needing approval (delete old checkpoints? force-push?)

Do not use for:
- questions answerable by project docs, code, or web
- low-stakes choices with obvious defaults
- short tasks where the user is clearly present

## Decision Flow

### 1. Classify the question (same as grill-all)

Before notifying the human:

1. **Is this answered by explicit user instruction?** → Use that.
2. **Is this a project fact?** → Check docs (OpenSpec, ADRs, README).
3. **Is this an implementation fact?** → Check code, tests, types.
4. **Is this a current external fact?** → Search web.
5. **Is this a human preference or high-stakes decision?** → Continue to step 2.

Only notify the human for **human preference, ambiguous trade-offs, or high-stakes decisions** that docs/code/web cannot resolve.

### 2. Prepare the notification

Structure:
```yaml
severity: warning | needs_decision | critical
question: <one sentence>
context: <2-3 lines of relevant state>
options:
  - option: <A>
    risk: <low/medium/high>
    reversible: <yes/no>
  - option: <B>
    ...
recommended: <which option you'd pick and why, 1 line>
fallback_if_no_reply: <what you'll do in 5 min if no reply>
reply_to: <file path or method>
```

### 3. Send the question over the configured transport

Send via whatever `transport.tier` resolved to (see Initialization and [`docs/feishu-setup.md`](../../../../docs/feishu-setup.md)):
- **Tier 1A** (in-loop): just emit the question as your output — the harness relays it.
- **Tier 1B** (Hermes detached): `messages_send(target, …)`.
- **Tier 1C** (OpenClaw detached): write the question to the mailbox/inbox the heartbeat turn posts.
- **Tier 2** (larksuite/cli): `lark-cli im +messages-send …`.
- **Tier 3** (webhook): `feishu-webhook-skill` (requires `FEISHU_TENANT_ACCESS_TOKEN` in env).

Message shape (any transport):
- Title: `⚠️ Experiment needs decision: <short summary>`
- Body: the structured question + options + recommendation + fallback
- Footer: how to reply (in chat for Tier 1/2; `Reply to: <file path>` for Tier 3)

### 4. Create file inbox and wait *(Tier 2 / 3 / 1C — the inbox-relayed transports)*

Create a feedback file:
```bash
mkdir -p .agent_runs/<run_id>
touch .agent_runs/<run_id>/feedback_inbox.md
echo "## Pending decision: <question>
Sent to Feishu at $(date)
Waiting for reply...

To reply, write your decision here and save." > .agent_runs/<run_id>/feedback_inbox.md
```

**Async wait:** Set a checkpoint timer (default 5 minutes for critical, 15 minutes for non-critical).

### 5. Checkpoint loop

At every safe checkpoint (or every 30-60 seconds during wait):
```bash
# Check for feedback
if grep -q "^DECISION:" .agent_runs/<run_id>/feedback_inbox.md 2>/dev/null; then
  # User replied!
  feedback=$(grep "^DECISION:" .agent_runs/<run_id>/feedback_inbox.md | head -1)
  # Parse and apply
fi
```

If feedback arrives:
1. Parse the decision
2. Apply it (if safe and feasible)
3. Record in decision log: `user replied at T+3min, applied: <feedback>`
4. Continue with user's correction

### 6. Provisional fallback if no reply

If the wait timer expires with no feedback:

**Classify fallback strategy:**
- **Auto-continue** (low-risk, reversible): proceed with the recommended option, log as provisional
- **Arena escalation** (high-stakes, conflicting options): call `agent-arena` with mode `deliberative_analysis` or `quick_panel`, get independent perspective, proceed with arena verdict (still provisional until user confirms)
- **Must-block** (irreversible, destructive, privacy-sensitive): do NOT proceed, save checkpoint, report blocker in final summary

Record in decision log:
```yaml
decision_id: exp_001_lr_choice
question: "Learning rate: 1e-4 or 5e-5?"
feishu_sent: 2024-06-23T20:15:00Z
user_reply: null
fallback: arena_deliberative_analysis
arena_verdict: "5e-5 (safer for fine-tuning)"
provisional: true
reversible: yes
```

### 7. Final report

At task completion, include:
- All decisions made
- Which were user-confirmed vs provisional
- Which used arena as fallback
- Artifact paths and reproduction commands

## Feishu Message Template

### Rich Text (for quick questions)
```json
{
  "msg_type": "post",
  "content": {
    "post": {
      "zh_cn": {
        "title": "⚠️ Experiment needs decision",
        "content": [
          [{"tag": "text", "text": "Question: Learning rate for fine-tuning?"}],
          [{"tag": "text", "text": "Context: Training ResNet on CIFAR-10, batch_size=64, current loss=0.8"}],
          [{"tag": "text", "text": "Options:\nA. 1e-4 (faster, risk overfitting)\nB. 5e-5 (safer, slower)"}],
          [{"tag": "text", "text": "Recommended: B (5e-5)\nFallback in 5min: Ask arena"}],
          [{"tag": "text", "text": "Reply to: .agent_runs/train_001/feedback_inbox.md", "style": ["bold"]}]
        ]
      }
    }
  }
}
```

### Card (for critical issues with buttons)
```json
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {"tag": "plain_text", "content": "🚨 Critical: Training failed"}
    },
    "elements": [
      {"tag": "div", "text": {"tag": "lark_md", "content": "**Issue:** OOM at epoch 3\n**Options:**\nA. Reduce batch size to 32\nB. Enable gradient checkpointing\nC. Stop and investigate"}},
      {"tag": "action", "actions": [
        {"tag": "button", "text": {"tag": "plain_text", "content": "Option A"}, "value": {"decision": "reduce_batch"}},
        {"tag": "button", "text": {"tag": "plain_text", "content": "Option B"}, "value": {"decision": "gradient_checkpoint"}},
        {"tag": "button", "text": {"tag": "plain_text", "content": "Stop"}, "value": {"decision": "stop"}}
      ]}
    ]
  }
}
```

**Note:** Interactive cards with buttons require a callback URL (Feishu bot webhook endpoint). If you don't have one, use rich text + file inbox instead.

## File Inbox Format

The user can reply by editing `.agent_runs/<run_id>/feedback_inbox.md`:

```markdown
## Decision needed: Learning rate

DECISION: Use 5e-5 (safer for fine-tuning, I can wait longer)
REASONING: Last time 1e-4 overfit quickly
```

Or:
```markdown
DECISION: Stop and investigate
REASONING: 20% accuracy drop is too suspicious
```

Agent parses lines starting with `DECISION:` and `REASONING:`.

## Arena Fallback Pattern

When using arena as fallback:

```bash
cat > /tmp/arena_packet.txt <<EOF
Question: Learning rate for ResNet fine-tuning on CIFAR-10?
Context: batch_size=64, current_loss=0.8, epoch=5/20
Options:
  A. 1e-4 (faster convergence, risk overfitting)
  B. 5e-5 (safer, slower)
My recommendation: B
User notification sent 5 minutes ago, no reply yet.
Use deliberative_analysis: find non-obvious option C or challenge the framing.
EOF

claude -p "$(cat /tmp/arena_packet.txt)" --skill agent-arena > /tmp/arena_verdict.txt
verdict=$(grep "Recommendation:" /tmp/arena_verdict.txt | head -1)
# Apply verdict, mark as provisional
```

## Integration with human-interruptible-unattended-runner

This skill extends `human-interruptible-unattended-runner` by adding:
- **Feishu delivery** (not just file checkpoints)
- **Explicit question routing** (grill-all logic)
- **Arena as fallback** (independent perspective when user unavailable)

Use both skills together:
```text
Use experiment-grill-feishu for decisions needing human input during long experiments.
Continue reversible work under provisional assumptions if I don't reply.
```

## Common Mistakes

- Notifying for questions answerable by docs/code
- Not setting `FEISHU_TENANT_ACCESS_TOKEN` env var
- Sending secrets or private data in Feishu messages
- Treating no reply as permission for irreversible actions
- Not recording provisional decisions in the decision log
- Forgetting to check feedback inbox at checkpoints

## Environment Setup

**Preferences are remembered** in `state/experiment-grill-feishu/config.yaml` (transport tier, target, wait times, fallback) after the first-use soft init — you don't re-choose them each session. **Secrets are not**: tokens stay in env vars and must be set each shell (or via your profile / a sourced `.env`):

```bash
# Secrets — env only, never in config.yaml (Tier 3 / webhook path)
export FEISHU_TENANT_ACCESS_TOKEN="your_token_here"

# These specific env vars OVERRIDE config.yaml when set (handy for one-off runs):
export EXPERIMENT_GRILL_CRITICAL_WAIT=300     # else timing.critical_wait_sec
export EXPERIMENT_GRILL_NORMAL_WAIT=900       # else timing.normal_wait_sec
export EXPERIMENT_GRILL_CHECK_INTERVAL=30     # else timing.check_interval_sec
export FEISHU_ALLOWED_USERS=ou_xxx            # else target.allowed_users
```

Get your token from: Feishu Open Platform → Create App → Get Tenant Access Token. Precedence applies to the vars above (**env > `config.yaml` > default**); other settings (transport, target, fallback, run_dir) come from `config.yaml` only.

## Quick Prompt

```text
Use experiment-grill-feishu. For critical decisions or ambiguities, ask me over my configured transport and wait 5 min. If I don't reply, use arena for high-stakes decisions or proceed provisionally for low-risk choices. Apply my correction immediately if I reply later.
```

## Status

`v0.1.0` preview. Requires `feishu-webhook-skill`, pairs with `grill-all`, `human-interruptible-unattended-runner`, and `agent-arena`.
