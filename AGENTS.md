# Tacto development

- Resume from [the active lifecycle plan](docs/exec-plans/active/lifecycle.md), then inspect Git state and the relevant code.
- Keep runtime resources under `install/`, CLI code under `src/`, and test artifacts/scripts under `.Tacto-temp/`.
- Preserve UTF-8 BOM in Windows PowerShell scripts: the supported runtime is Windows PowerShell 5.1.
- Preserve other installations, user SSH keys and unrelated MCP entries. Exercise destructive lifecycle scenarios only in isolated installations.
- Record changed requirements and milestone evidence in the active plan. Current design lives in [architecture](docs/ARCHITECTURE.md) and `docs/design/`; release results live in `docs/histories/`.
