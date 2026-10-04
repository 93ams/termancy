//! `lib/cfg` - configuration: resolution, layering and the tooling around it.
//!
//! This is the module root, and the module's public surface. It imports only
//! `std`; it knows nothing about any app or any CLI framework in this
//! repository, so a daemon, a server or a test harness can use it directly.
//!
//! ## Contents
//!
//!   * `cfg.zig`        - `Manager(ConfigT)`: an arena-backed resolver that
//!                        starts from struct defaults and overlays environment
//!                        variables, JSON and typed overrides. The arena is what
//!                        makes `deinit` total: every string it allocates is
//!                        released at once, so there is no per-field cleanup to
//!                        get wrong.
//!   * `loader.zig`     - `load` / `mergeJson` / `generateSchema` and the
//!                        profile + watcher helpers. This is the entry point the
//!                        `tigershark` CLI uses.
//!   * the remaining files are the *tooling* around a configuration: provenance
//!     (`config_lineage`), presentation (`config_diff`, `config_dryrun`),
//!     profiles and TOML mutation (`profiles`, `toml_mutator`), versioning
//!     (`schema_migration`), feature gates (`ota_flags`), cached remote state
//!     (`remote_config`) and comptime extraction (`comptime_config`).
//!
//! ## History, because it explains the shape
//!
//! Everything except `cfg.zig` was written under `app/cli/lib/settings/`, and
//! `cfg.zig` was a second, unused resolver that did not compile. Configuration
//! has no CLI in it, so it now lives here and `lib/cli` re-exports it for its
//! own consumers. `app/cli/lib/ROADMAP.md` item U-0 records that decision.
//!
//! **Still open, and recorded rather than hidden:** `cfg.Manager` and
//! `loader.load` are two resolvers that overlap on defaults, environment
//! binding and JSON overlay. They are both correct and both tested; unifying
//! them is a deliberate piece of work, not a move, because the `tigershark
//! config` command and its tests depend on `loader`'s exact semantics. See
//! `app/cli/lib/ROADMAP.md` U-2.

const std = @import("std");

/// The arena-backed resolver. Reachable both as `cfg.Manager` and, for the
/// consumers that used the old path, as `cfg.manager.Manager`.
pub const Manager = @import("cfg.zig").Manager;

/// The file is also exposed under its own name so `refAllDecls` below can reach
/// its tests, and so callers may write `cfg.cfg.Manager` if they prefer.
pub const manager = @import("cfg.zig");

/// Configuration resolution: load, merge JSON, generate a JSON Schema, and the
/// profile/watcher helpers. Previously `cli.zconfig`.
pub const loader = @import("loader.zig");
pub const mergeJson = loader.mergeJson;
pub const ProfileManager = loader.ProfileManager;

/// Provenance tracking: which layer last set a field, and where it came from.
pub const config_lineage = @import("config_lineage.zig");

/// Visual diff of an active configuration against its defaults.
pub const config_diff = @import("config_diff.zig");

/// Override parsing and a pass/fail matrix for a dry run.
pub const config_dryrun = @import("config_dryrun.zig");

/// Sequential schema-version migration.
pub const schema_migration = @import("schema_migration.zig");

/// Extraction of JSON embedded in a programmable Zig config file.
pub const comptime_config = @import("comptime_config.zig");

/// Multi-tenant context switching inside a TOML file.
pub const profiles = @import("profiles.zig");

/// Comment-preserving TOML key mutation.
pub const toml_mutator = @import("toml_mutator.zig");
/// A comment-preserving TOML document model, for mutations that must not destroy the file.
pub const toml_doc = @import("toml_doc.zig");
/// Encrypted configuration at rest: XChaCha20-Poly1305 over a PBKDF2-HMAC-SHA256 key.
pub const encrypted_config = @import("encrypted_config.zig");

/// Remote configuration with an ETag-keyed local cache.
pub const remote_config = @import("remote_config.zig");

/// Feature-flag gates loaded from configuration.
pub const ota_flags = @import("ota_flags.zig");

/// `.env` parsing, with recursive variable expansion and cycle detection.
///
/// The tree could previously *write* a `.env` (`writeDotEnv`, the `dotenv` export
/// format) and had no reader for one, so a program could not read back what it
/// wrote.
pub const dotenv = @import("dotenv.zig");

/// The comptime data binder: one struct resolved from flags, environment, files
/// and its own defaults, with the precedence stated as the caller's layer order.
pub const binder = @import("binder.zig");

/// A bounded YAML subset: block mappings, sequences and scalars, with every
/// unsupported construct refused by name rather than read as text.
pub const yaml = @import("yaml.zig");

/// Format detection and a flat, dotted-key view of a config file, ready to hand to
/// `binder` as a `.file` layer.
pub const format = @import("format.zig");

/// Config scalar types and their string grammars: `DurationMs` and `ByteSize`.
///
/// These were lifted out of `app/bus/config/root.zig`, which was their only home
/// and their only user. A duration and a byte size are generic config behaviour -
/// `kvs`, `scp` and the CLI all take them in the same two shapes - so they belong
/// in the generic config library, not in one app.
pub const scalar = @import("scalar.zig");

/// The config scalar grammars, re-exported flat for the common case:
/// `cfg.parseDurationMs("2m")`.
///
/// Note the shape: `scalar.zig` follows the file-as-type rule, so the *file* is
/// `DurationMs` - `scalar.DurationMs` does not exist and would be wrong to write.
pub const DurationMs = scalar;
pub const ByteSize = scalar.ByteSize;
pub const parseDurationMs = scalar.parseDurationMs;
pub const parseByteSize = scalar.parseByteSize;
/// Parses a string into a config field type: "does `2m` belong in *this* field".
pub const parseValue = scalar.parseValue;

test {
    // `refAllDecls` is shallow: it reaches the declarations of the namespaces it
    // is handed, and a `test` block is collected only when a declaration in that
    // namespace references it. Each namespace is therefore named explicitly.
    // `app/cli/lib/ROADMAP.md` M-2 records the rule and the control experiment.
    std.testing.refAllDecls(@import("cfg.zig"));
    std.testing.refAllDecls(loader);
    std.testing.refAllDecls(config_lineage);
    std.testing.refAllDecls(config_diff);
    std.testing.refAllDecls(config_dryrun);
    std.testing.refAllDecls(schema_migration);
    std.testing.refAllDecls(comptime_config);
    std.testing.refAllDecls(profiles);
    std.testing.refAllDecls(toml_mutator);
    std.testing.refAllDecls(toml_doc);
    // Moved here from app/cli/lib/secrets, which is why its tests are collected by this root
    // rather than by the cli test root.
    std.testing.refAllDecls(encrypted_config);
    std.testing.refAllDecls(remote_config);
    std.testing.refAllDecls(ota_flags);
    std.testing.refAllDecls(scalar);
    // Named explicitly, like every other namespace above. Adding the `pub const`
    // without this line compiles and silently runs zero of `dotenv.zig`'s tests -
    // which is precisely the failure M-2 was written about, and it happened again
    // here: the first test run after this module landed reported the same total as
    // before it existed.
    std.testing.refAllDecls(dotenv);
    std.testing.refAllDecls(binder);
    std.testing.refAllDecls(yaml);
    std.testing.refAllDecls(format);
}
