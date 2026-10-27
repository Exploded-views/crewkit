---
# agent-practice settings. Copy to .claude/agent-practice.local.md (project, git-ignored)
# or ~/.claude/agent-practice.md (user). Every key is optional; see the plugin README.
owner_name: "the owner"
orchestrator_name: orchestrator
state_dir: ~/.local/state/crewkit   # holds decisions.md and state.md
velocity_file: ~/.local/state/crewkit/velocity.md   # measured merge velocity + the command to recompute it
repo: <owner>/<repo>
required_check: ci-ok
extra_checks: []            # e.g. [workflow-lint]
sensitive_paths:            # regexes; extend for your stack
  - '^migrations/'
  - '(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|Cargo\.lock|go\.sum|poetry\.lock|uv\.lock)$'
  - '^\.github/workflows/'
freshness_command: ""       # e.g. "<your-freshness-script> <pr> -R <repo>"
land_command: ""            # e.g. "<your-lander> <pr> <pr> ..."
health_url: ""              # e.g. https://app.example/healthz
verify_workflow: ""         # e.g. .github/workflows/verify.yml
review_model: opus
implement_model: sonnet
high_risk_areas: [money, trust, security, authorization, infrastructure]
reply_timeout_urgent: 10m
reply_timeout_normal: 15m
pool_command: ""            # e.g. "bitc run heavy --"
mem_floor_gb: 6
durable_dir: ~/.local/state/agent-practice
page_command: ""
---

# agent-practice settings

Free-form notes for your sessions can go below the frontmatter.
