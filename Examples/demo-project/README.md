# AgentKeyBox demo project

This fixture demonstrates the approval loop without calling any external API.

1. Add this folder as a project in AgentKeyBox.
2. Save any test credential for this project.
3. Ask Claude Code or Codex to use AgentKeyBox `run_with_secret` with:
   - `env_var`: `DEMO_API_KEY`
   - `command`: the absolute path to `verify-secret.sh`
4. Approve the request in AgentKeyBox.

The script only checks that the secret exists; it never prints it.
