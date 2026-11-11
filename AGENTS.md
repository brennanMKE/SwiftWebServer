# AGENTS.md — rules for autonomous agents

Agents in this repo run unattended for hours. **A macOS system prompt (keychain, firewall, privacy/TCC, authorization) blocks the agent until a human clicks it, which can stall hours of work.** Avoiding prompts is a hard requirement, not a nicety.

## Never trigger a system prompt

| Prompt source | What triggers it | Do this instead |
|---|---|---|
| Keychain access / "wants to use your confidential information" | `SecPKCS12Import` without memory-only, `SecItemAdd`/`SecItemCopyMatching`, `security` CLI, `SecIdentity` lookups by label, `URLSession` client certs from keychain | `SecPKCS12Import` with `kSecImportToMemoryOnly: true`. Never run `security`. Never read, add, delete, or modify keychain items or trust settings |
| Certificate trust ("You are making changes to your Certificate Trust Settings") | `security add-trusted-cert`, `SecTrustSettingsSetTrustSettings` | Accept test certs in-process: `sec_protocol_options_set_verify_block` / `URLSessionDelegate` challenge handling scoped to the test |
| Application firewall ("accept incoming network connections?") | Listening on a non-loopback interface with an unsigned, freshly built binary while the firewall is on | Bind listeners and tests to `127.0.0.1` / `::1` only (`NWParameters.requiredLocalEndpoint` or `NWEndpoint.hostPort(host: .ipv4(.loopback), …)`). Port 0 for tests |
| Local Network privacy ("find and connect to devices on your local network") | Connecting to LAN addresses, Bonjour/mDNS browsing or advertising | Only connect to loopback. No `NWBrowser`, no Bonjour service advertising |
| Privacy/TCC (Files & Folders, Desktop/Documents/Downloads, Full Disk Access, Accessibility, Screen Recording, Camera, Mic) | Reading `~/Desktop`, `~/Documents`, `~/Downloads`, other apps' containers, `osascript`/System Events, screen capture | Stay inside the repo, `.build/`, and the session scratchpad/`$TMPDIR` |
| Authorization (`sudo`, admin password) | `sudo`, `launchctl` system domains, `/Library` writes, `pfctl`, `dtrace` | Never use `sudo`. Use user-level tools only |
| Code signing / developer tools prompts | `codesign` with keychain identities, `xcodebuild` signing, Instruments attach (`DevToolsSecurity`) | `swift build`/`swift test` only; no signing. Profile with `sws-bench`, not Instruments attach |
| Docker / VM permissions | Docker Desktop first launch | Skip Docker-based checks (Autobahn) unless the owner has started Docker |

Before adding any API from Security.framework, Network.framework discovery, or file access outside the repo, check this table. If unsure whether something prompts, don't do it — ask the orchestrator.

## Detect and cancel prompts

Run every command that launches a server, a network client, a test suite, or a benchmark through the guard:

```bash
scripts/guarded.sh -t 600 -- swift test
scripts/guarded.sh -t 120 -- .build/debug/SwiftWebServer
```

`scripts/guarded.sh` enforces a wall-clock timeout (exit 124) and watches for new SecurityAgent / CoreServicesUIAgent / UserNotificationCenter processes that appear while the command runs. On detection it kills the command's process group, which dismisses the dialog, and exits 125.

Also treat these as prompt symptoms and stop immediately: a TLS handshake, `receive`, or test that hangs with no output; `errSecInteractionNotAllowed` / `-25308` / `errSecAuthFailed`; `SecurityAgent` in `pgrep -lx SecurityAgent`. Kill your own process (never kill SecurityAgent or system daemons), then fix the cause using the table above. **Never retry the same action** — retrying re-prompts.

If a prompt was triggered, report it to the orchestrator: what ran, what the prompt was, and anything persisted (it may not be removed by you — the owner decides; never run cleanup against the keychain or system settings yourself).

## Other unattended-run rules

- Every server, client, and test must have a timeout. Swift Testing: `@Test(.timeLimit(.minutes(1)))` on anything that does I/O.
- Never leave background processes running. Kill servers you start; prefer port 0 to avoid colliding with other agents.
- Other agents work in parallel worktrees: never bind fixed ports (8080, 8443) in tests, never write outside your worktree except `$TMPDIR`.
- No interactive commands (`git rebase -i`, editors, pagers): use `--no-pager`, `-y`, `GIT_EDITOR=true`.
