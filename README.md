# sbx-workspace

A workspace repository for sbx sandboxes, using [yasukei/sbx-kits](https://github.com/yasukei/sbx-kits) and [yasukei/agent-skills](https://github.com/yasukei/agent-skills).

## Initial setup

### On the host

```bash
# Allow kits from github.com/yasukei/ (one-time setup)
sbx settings set kit.allowedSources '["docker.io/","dhi.io/","github.com/yasukei/"]'

# Clone this repository
gh repo clone yasukei/sbx-workspace
cd sbx-workspace

# Start a new sandbox in clone mode
sbx run shell \
  --clone \
  --kit sbx/claude-mixin --kit-arg claude-mixin.model=opus --kit-arg claude-mixin.reasoningEffort=high \
  --kit sbx/codex-mixin --kit-arg codex-mixin.model=gpt-6.2-sol --kit-arg codex-mixin.reasoningEffort=high \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=base" \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=network" \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=claude-config" \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=codex-config" \
  --name "sbx-workspace-$(date +%Y%m%d)"
```

### In the sandbox

```bash
# Clone all repositories accessible to the authenticated GitHub user
./clone-repos.sh

# Log in to Claude
claude auth status --text     # Check login status
claude auth login --claudeai  # Log in if not already logged in

# Log in to Codex
codex login status            # Check login status
codex login                   # Log in if not already logged in

# Set up yasukei/agent-skills
#   Claude: /plugin -> loaded automatically from claude.ai
#   Codex:  /plugins -> add 'yasukei/agent-skills' via 'Add Marketplace' -> install the plugin
```
