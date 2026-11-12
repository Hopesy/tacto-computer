# Architecture

Tacto packages a Windows CUA daemon and optional reverse SSH tunnel as an agent-independent stdio MCP endpoint. Node CLI commands orchestrate the PowerShell installer and export/probe connections. The standalone Windows package uses Windows PowerShell and .NET Framework. Linux VPS setup runs under the SSH user's home directory.

Runtime state belongs to one installation identity, named pipe and set of login tasks. Windows callback authorization restricts the VPS key to the bridge entrypoint; VPS tunnel authorization restricts forwarding to the allocated loopback port. Driver binaries come from the pinned official release with archive hash and Authenticode checks.

- [Lifecycle and agent integration design](design/lifecycle.md)
- [Development and verification commands](DEVELOPMENT.md)
- [Verification evidence](VERIFICATION.md)
