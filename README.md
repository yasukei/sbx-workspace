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
  --kit sbx/claude-mixin \
  --kit sbx/codex-mixin \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=base" \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=network" \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=claude-config" \
  --kit "git+https://github.com/yasukei/sbx-kits.git#dir=codex-config" \
  --name "sbx-workspace-$(date +%Y%m%d)"
```

### In the sandbox

```bash
# Clone all repositories accessible to the authenticated GitHub user,
# except those listed in exclude-repos.txt.
# Already-cloned ones are fetched (--prune), and pulled if on a clean main
./clone-repos.sh

# Check Claude / Codex login status (you should already be logged in via sbx's credential mechanism)
claude auth status --text
codex login status

# Set up yasukei/agent-skills
#   Claude: /plugin -> loaded automatically from claude.ai
#   Codex:  /plugins -> add 'yasukei/agent-skills' via 'Add Marketplace' -> install the plugin

# Set the default model and effort level
#   Claude: /model and /effort
#   Codex:  /model
```

## Tests

`tests/test-clone-repos.sh` tests `clone-repos.sh` offline: it uses local
repositories via `file://` URLs and a stub `gh`, so no network access or
GitHub login is needed. It also runs [ShellCheck](https://www.shellcheck.net/),
which must be installed (e.g. `apt install shellcheck`).

```bash
tests/test-clone-repos.sh
```
