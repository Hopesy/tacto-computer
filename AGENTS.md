# Tacto development

- Read the latest [release history](docs/histories/2026-11-12-v0.3.0.md), check `docs/exec-plans/active/` for newer work, then inspect Git state and the relevant code.
- Keep runtime resources under `install/`, CLI code under `src/`, and test artifacts/scripts under `.Tacto-temp/`.
- Preserve UTF-8 BOM in Windows PowerShell scripts: the supported runtime is Windows PowerShell 5.1.
- Preserve other installations, user SSH keys and unrelated MCP entries. Exercise destructive lifecycle scenarios only in isolated installations.
- Record changed requirements and milestone evidence in the active plan. Current design lives in [architecture](docs/ARCHITECTURE.md) and `docs/design/`; release results live in `docs/histories/`.
