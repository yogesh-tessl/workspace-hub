# Hermes Local Patches

Patches in this directory are applied by `harness-update.sh` after each
`hermes update` completes. This replaces the need to fork NousResearch/hermes-agent.

## How it works

1. `hermes update` pulls from upstream NousResearch/hermes-agent
2. `harness-update.sh` runs `git apply` on each `*.patch` file in this directory
3. Patches that fail to apply (already applied, conflict) are logged as warnings

## Creating a patch

```bash
cd ~/.hermes/hermes-agent
# Make your change
git diff > ~/workspace-hub/config/agents/hermes/patches/my-fix.patch
# Or for a specific file:
git diff hermes > ~/workspace-hub/config/agents/hermes/patches/fix-shebang.patch
```

## Current patches

None — the shebang is handled by `hermes update` itself (rewrites to local venv).
Patches are only needed for fixes that upstream doesn't accept.
