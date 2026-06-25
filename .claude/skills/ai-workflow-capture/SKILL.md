---
name: ai-workflow-capture
description: Assemble the ai-artifacts/ folder for an AI-assisted submission — per-phase transcripts, an honest tools-and-workflow note, and a commit-history sanity check. Use in the docs phase to package how the work was done.
---

# AI workflow capture

The `ai-artifacts/` folder shows a reviewer *how* the work was produced. It must be honest:
name the real tools, subagents, and skills, and flag any stand-ins.

## Per-phase transcript (`ai-artifacts/phaseN-<slug>.md`)

Each file contains:

- **Role** — which agent played the phase (and, if a stand-in, say so plainly:
  "played by the general-purpose subagent — the bespoke X agent is not installed").
- **Skills assumed** — which skills the agent used; if not installed, note the knowledge was
  inlined.
- **PROMPT** — the verbatim prompt pasted to the agent.
- **OUTPUT** — the agent's actual result.
- **Verification** — what the orchestrator independently checked (commands + output). Record
  bugs caught here (e.g. the NullStore throttle no-op).

**Never embed secrets.** Redact real API keys (`<REDACTED_DEV_API_KEY>`) before saving.

## Folder README (`ai-artifacts/README.md`)

One page covering:

- **Tools used:** Claude Code (model), and the specific subagents + skills per phase, as a table.
- **Workflow:** how each playbook phase mapped to an agent and how artifacts/commits were
  produced. State where stand-ins were used instead of bespoke agents/skills.
- **Artifact checklist:** confirm every `phaseN-*.md` is present and named.
- **Commit-history check:** `git log --oneline` should read as a clean phase-by-phase story
  (scaffold → feature → tests → stretch → docs). Paste it.

## Sanity checks before calling it done

```bash
ls ai-artifacts/                        # every phase present?
git log --oneline -8                    # maps to phases?
grep -rIl -E '[0-9a-f]{40}' ai-artifacts/ | grep -v REDACTED   # stray secrets? (should be empty)
```
