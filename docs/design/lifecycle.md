# Lifecycle and agent integration

Status: accepted. Source: user request, 2026-11-12.

Priorities: complete/offline uninstall, transactional upgrade with recovery, unobtrusive installation, then opt-in idle updates. Installation identity, device name, pipe and keys survive upgrades. Only resources owned by this installation are removed. A remote cleanup failure must allow local cleanup and produce an actionable receipt.

Updates stage a matched runtime, driver and target-bound Skill before stopping the current service. An on-disk journal and previous configuration allow recovery after process interruption as well as automatic rollback on validation failure. Existing MCP connections and named CLI sessions defer normal updates. Health verification exercises MCP initialize/tools/list/health_report, including the Windows interactive session, UIA and screen capture.

Health acceptance follows the official schema-1 semantics: `failed` or missing/failed core checks (binary version, platform, session) reject activation; `degraded` reports the failed capability and hint while retaining a usable connection. A real third-party Windows UIA provider intermittently exceeded its timeout during acceptance. Requiring every optional capability to pass would trigger an unrelated rollback of a working transport. Preserve the complete report, allow 60 seconds for diagnostics, bound retries, and verify the real MCP endpoint separately. Core failure and an invalid Driver still exercise rollback.

Activation explicitly requests binary, platform, session and screen-capture checks through `health_report.include`; `check` and `probe --health` request the full report including UIA. Task readiness and MCP verification are separate: a newly running task can still be initializing. Instance-specific status includes the matching PID file. A bounded readiness wait precedes failure recovery.

Windows PowerShell 5.1 processes receive their stock system module directory before startup. Node applies this at its PowerShell spawn boundary; generated local MCP server entries carry the same `PSModulePath`, and standalone installer/bridge scripts reset their process-local path. This prevents inherited PowerShell 7 modules from shadowing 5.1 cmdlets when Node sits between the two hosts. Other child commands retain their environment.

`install/windows/Download.ps1` owns archive transfer and verification. Each transfer keeps the existing 15-second connect and 120-second total limits, with three bounded attempts. curl resumes a retained `.partial` using HTTP Range, including on a later installer invocation. A server rejecting byte ranges gets one clean transfer; a completed checksum mismatch discards the bad partial. Only the expected SHA256 promotes bytes to the archive, and installation still verifies Authenticode. When curl is unavailable, the Windows PowerShell web-request fallback downloads from the start.

Full uninstall removes owned services, configuration and payloads before pruning the empty installation root. An IO failure removing that final empty directory produces a warning and preserves successful cleanup; failures in the earlier cleanup steps still propagate. This covers applications holding the installation directory as their working directory without terminating those applications.

The thin Tacto Skill binds CLI and a named MCP server to the controlled platform, and loads adapted official references (see [CLI and Skills](cli-and-skills.md)). It obtains release-matched guidance through get_guide, uses live tool schemas for batching and incremental observations, rebuilds targets after reconnecting, coordinates concurrent agents, and makes browser profile selection explicit. Diagnostic recording is optional and preview capabilities are discovered at runtime.

Official research: https://cua.ai/docs/cua-driver ; relevant pages are connect-your-agent, operate, vms-and-remote, browsers, how-cua-driver-works, and the health_report/run_steps/get_window_state references. Research corpus and detailed coverage are in `.Tacto-temp/cua-docs-review-20261112/`.
