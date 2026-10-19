# `sys`

The operating system as a CLI needs it. Grouped by concern, every file also reachable by a
flat name (`sys.dirs`).

Nothing starts a thread or touches the network unless the function called says so.

## System

| | |
|---|---|
| `dirs` | XDG, macOS, and Windows known folders |
| `exe` | |
| `env` | CI detection, `DO_NOT_TRACK`, elevation |
| `process` | capture, stream, `which`, `$EDITOR`, open a URL |
| `signal` | Ctrl-C as a flag, exit 130 |
| `files` | atomic writes, lock files, a 0600 state store |
| `daemon` | |
| `proctitle` | hide secret arguments from `ps`, Task Manager included |
| `dynlib` | hot reload |

## Security

| | |
|---|---|
| `secure` | page-locked, dump-excluded, zero-on-free `Allocator`; constant-time `eql`; `Secret` |
| `sandbox` | path policy against traversal and symlink escapes |
| `oauth` | PKCE, device flow |
| `webauthn` | request and assertion types, every relying-party check, ES256 and EdDSA signatures from COSE keys, sign counts |
| `ctap` | CTAP2 over CTAPHID to a security key, with its PIN; the Linux hidraw transport |
| `cbor` | |

## Observability

| | |
|---|---|
| `log` | text, logfmt, or JSON lines; styled levels, fields, prefixes, callers; redaction by key and of known secret values; a `std.log` adapter |
| `crash` | panic banner, JSON report without argv or environment |
| `profiler` | |
| `trace` | W3C `traceparent` |
| `telemetry` | off unless the user consents; honors `DO_NOT_TRACK` and CI |

## SSH

| | |
|---|---|
| `keys` | public keys, fingerprints, `authorized_keys`; Ed25519, ECDSA, and RSA signatures checked; Ed25519 keys made and kept in OpenSSH's format, under a passphrase or not; `ssh-keygen -Y` signatures made and checked |
| `Server` | logins by key or password, terminals, resizes, signals, exit statuses, opt-in `ssh -L` and `ssh -R` forwarding; ML-KEM hybrid post-quantum key exchange, ChaCha20-Poly1305 and AES-GCM, strict key exchange |
| `Client` | host keys checked against `known_hosts`, Ed25519 keys from files or the ssh-agent, or passwords, commands and terminals, `ssh -L` |
| `Agent` | ssh-agent at `$SSH_AUTH_SOCK` |
| `known_hosts` | |
| `mnemonic` | BIP 39 words for a secret, as melt |

## Web

`web.Server`: a terminal over a browser's WebSocket, with the SSH session's surface, a token,
an origin check, and an xterm.js page with a `title`. `handlerFor` makes a typed handler,
`link` the address to print; `web.Client` is for tests.

## Distribution

| | |
|---|---|
| `version` | semver |
| `update` | release lookup with or without pre-releases, SHA-256 and Ed25519 verification, bare, `.tar.gz`, or `.zip` assets, atomic swap with rollback |
| `manifests` | Homebrew, Scoop, PKGBUILD, Debian control |
| `remote` | a file over HTTP with an ETag cache that serves the last copy offline |
