# Security

## Reporting a vulnerability

Report it privately through GitHub:
[Security → Report a vulnerability](https://github.com/93ams/termancy/security/advisories/new).
Please do not open a public issue. Say what is affected, how to reproduce it, and what an
attacker gains.

You can expect an answer within a week. A fix ships in a new release, with an advisory that
credits you unless you ask otherwise. Only the latest release is supported.

## What deserves a report

Most of termancy is local tooling, but some of it faces the network or untrusted input:

| Area | Where |
|---|---|
| The SSH server and client | `sys.ssh`, `termancy serve`, `termancy ssh run` |
| The browser terminal | `sys.web`, `termancy serve --web` |
| Self-update and release signatures | `sys.update`, `termancy update`, `termancy release` |
| Parsers of untrusted input | `cfg`'s formats, SSH keys and packets, CBOR, escape sequences, Markdown, PNG, GIF, JPEG, TrueType, tapes |
| Secrets | `cfg` secret references and redaction, `sys.secure`, `cli`'s `.secret` flags |

## Before you rely on it

- **Not audited.** The SSH protocol, the browser terminal, and the update chain are reviewed
  and tested (against OpenSSH, real browsers, and fuzzers), but no independent party has
  audited them.
- **Cryptography.** Every primitive (SHA-2, HMAC, HKDF, Ed25519, ECDSA, RSA verification,
  X25519, ML-KEM, AES, ChaCha20, Poly1305, bcrypt-pbkdf) is Zig's standard library's. This
  repository only composes them, as the protocols specify: SSH's packet protection
  (`chacha20-poly1305@openssh.com`, AES-GCM), key exchange, and key files.
- **`serve` runs a command for whoever connects.** Over SSH, only keys in
  `--authorized-keys` get in; with `--web`, only holders of the printed token. `--anyone`
  turns both off: it is for demos on trusted networks. With `--web --anyone` off the
  loopback, a web page that someone on that network visits can also reach it.
- **`--web` has no TLS.** It listens on loopback by default; anywhere else, put it behind a
  reverse proxy that adds TLS.
- **Updates are signed.** `termancy update` installs only archives whose Ed25519
  signature matches the key compiled into termancy.
