//! End-to-end tests: `snek` run as a process in `test/fixtures` (or a directory under it),
//! with an empty environment plus what each case sets, comparing standard output, standard
//! error, and exit status.
//!
//! The editing commands run on files in a run step's own output directory, so the
//! checked-in fixtures never change (see `addEditChains`); so do the generators, whose
//! generated project is then built and run by `zig build` (see `addProjectChains`). The
//! generated completion scripts are also run by each shell the host has: bash, zsh, fish,
//! and PowerShell (`pwsh`).

/// What `snek --version` prints: the version in `build.zig.zon`.
const version = @import("../build.zig.zon").version;
const std = @import("std");
const builtin = @import("builtin");

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    env: []const [2][]const u8 = &.{},
    /// The working directory, relative to `test/fixtures`.
    cwd: []const u8 = ".",
    /// Standard input; none when null.
    stdin: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    /// Checked instead of `stdout` when only part of the output is stable: a substring.
    stdout_contains: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    status: u8 = 0,
};

const snek_toml_json =
    \\{
    \\  "name": "demo",
    \\  "debug": false,
    \\  "server": {
    \\    "host": "localhost",
    \\    "port": 8080,
    \\    "tags": [
    \\      "a",
    \\      "b"
    \\    ]
    \\  }
    \\}
    \\
;

const snek_toml_yaml =
    \\name: demo
    \\debug: false
    \\server:
    \\  host: localhost
    \\  port: 8080
    \\  tags:
    \\    - a
    \\    - b
    \\
;

const cfg_subcommands =
    "get\tPrint one value\n" ++
    "keys\tList every key that has a value\n" ++
    "show\tPrint the whole effective configuration\n" ++
    "explain\tShow where each value comes from\n" ++
    "env\tPrint the configuration as shell variable exports\n" ++
    "profile\tList profiles, or choose the one used by default\n" ++
    "set\tSet a value in the config file\n" ++
    "unset\tRemove a key from the config file\n" ++
    "edit\tOpen the config file in your editor, and check it before saving\n" ++
    "convert\tConvert a file to another format\n" ++
    "validate\tCheck that files parse, and match a schema\n" ++
    "fmt\tRewrite files in canonical form\n" ++
    "redact\tPrint a file with its secrets hidden, to share it\n" ++
    "diff\tCompare two files, or two layers, key by key\n" ++
    "encrypt\tEncrypt a file for keeping secrets in a repository\n" ++
    "decrypt\tPrint an encrypted file's contents\n" ++
    "merge\tMerge files into one\n" ++
    "init\tWrite a starter config file\n" ++
    "schema\tInfer a JSON Schema, or check files against one\n";

const unknown_format = "unknown format (use .toml, .yaml, .json, .jsonc, .zon, .env, or .ini)";

const get_usage = "Usage:\n  snek cfg get [flags] <key>\n";

const cases = [_]Case{
    // Discovery and layering.
    .{
        .name = "discovers snek.toml",
        .args = &.{ "cfg", "get", "server.port" },
        .stdout = "8080\n",
    },
    .{
        .name = "discovers snek.yaml",
        .args = &.{ "cfg", "explain" },
        .cwd = "yaml",
        .stdout =
        \\KEY          VALUE      SOURCE
        \\name         from-yaml  file (./snek.yaml)
        \\server.port  7001       file (./snek.yaml)
        \\
        ,
    },
    .{
        .name = "discovers snek.json",
        .args = &.{ "cfg", "explain" },
        .cwd = "json",
        .stdout =
        \\KEY          VALUE      SOURCE
        \\name         from-json  file (./snek.json)
        \\server.port  7002       file (./snek.json)
        \\
        ,
    },
    .{
        .name = "discovers snek.env",
        .args = &.{ "cfg", "explain" },
        .cwd = "env",
        .stdout =
        \\KEY          VALUE     SOURCE
        \\name         from-env  file (./snek.env)
        \\server.port  7003      file (./snek.env)
        \\
        ,
    },
    .{
        .name = "later files win",
        .args = &.{ "cfg", "get", "server.port", "-c", "snek.toml", "-c", "extra.yaml" },
        .stdout = "9090\n",
    },
    .{
        .name = "later files win, reversed",
        .args = &.{ "cfg", "-c", "extra.yaml", "-c", "snek.toml", "explain", "server.port" },
        .stdout =
        \\KEY          VALUE  SOURCE
        \\server.port  8080   file (snek.toml)
        \\
        ,
    },
    .{
        .name = "-c with an unknown extension",
        .args = &.{ "cfg", "-c", "notes.txt", "get", "a" },
        .stderr = "snek: notes.txt: " ++ unknown_format ++ "\n",
        .status = 1,
    },
    .{
        .name = "-c with a missing file",
        .args = &.{ "cfg", "-c", "missing.toml", "get", "a" },
        .stderr = "snek: missing.toml: no such file\n",
        .status = 1,
    },
    .{
        .name = "TOML syntax error",
        .args = &.{ "cfg", "-c", "bad.toml", "get", "a" },
        .stderr = "snek: bad.toml:2:5: expected a value\n",
        .status = 1,
    },
    .{
        .name = "YAML syntax error",
        .args = &.{ "cfg", "-c", "bad.yaml", "get", "a" },
        .stderr = "snek: bad.yaml:3:2: inconsistent indentation\n",
        .status = 1,
    },
    .{
        .name = "profile overlays files",
        .args = &.{ "cfg", "--profile", "prod", "get", "server.host" },
        .stdout = "example.com\n",
    },
    .{
        .name = "profile is explained",
        .args = &.{ "cfg", "--profile", "prod", "explain", "server.host" },
        .stdout =
        \\KEY          VALUE        SOURCE
        \\server.host  example.com  profile (./snek.toml)
        \\
        ,
    },
    .{
        .name = "SNEK_PROFILE selects the profile",
        .args = &.{ "cfg", "get", "server.host" },
        .env = &.{.{ "SNEK_PROFILE", "prod" }},
        .stdout = "example.com\n",
    },
    .{
        .name = "unknown profile",
        .args = &.{ "cfg", "--profile", "qa", "get", "server.host" },
        .stderr = "snek: no profile \"qa\" in the loaded files\n",
        .status = 1,
    },
    .{
        .name = "--profile beats SNEK_PROFILE",
        .args = &.{ "cfg", "--profile", "qa", "get", "server.host" },
        .env = &.{.{ "SNEK_PROFILE", "prod" }},
        .stderr = "snek: no profile \"qa\" in the loaded files\n",
        .status = 1,
    },
    .{
        .name = "unknown profile from SNEK_PROFILE",
        .args = &.{ "cfg", "get", "server.host" },
        .env = &.{.{ "SNEK_PROFILE", "qa" }},
        .stderr = "snek: no profile \"qa\" in the loaded files\n",
        .status = 1,
    },
    .{
        .name = "environment overrides files",
        .args = &.{ "cfg", "--env-prefix", "APP", "get", "server.port" },
        .env = &.{.{ "APP_SERVER_PORT", "7000" }},
        .stdout = "7000\n",
    },
    .{
        .name = "flags read the environment",
        .args = &.{ "cfg", "get", "server.port" },
        .env = &.{.{ "SNEK_CONFIG", "snek.toml,extra.yaml" }},
        .stdout = "9090\n",
    },
    .{
        .name = "SNEK_CONFIG list in order",
        .args = &.{ "cfg", "explain" },
        .env = &.{.{ "SNEK_CONFIG", "extra.yaml,app.env" }},
        .stdout =
        \\KEY          VALUE  SOURCE
        \\app_name     demo   file (app.env)
        \\server.port  80     file (app.env)
        \\
        ,
    },
    .{
        .name = "--set overrides everything",
        .args = &.{ "cfg", "--set", "server.port=1", "get", "server.port" },
        .env = &.{.{ "APP_SERVER_PORT", "7000" }},
        .stdout = "1\n",
    },
    .{
        .name = "--set infers types, last wins",
        .args = &.{
            "cfg",   "--set",  "x=1",  "--set",   "x=hello world", "--set", "r=1.5",
            "--set", "n=null", "show", "--layer", "override",      "-o",    "json",
        },
        .stdout = "{\n  \"x\": \"hello world\",\n  \"r\": 1.5,\n  \"n\": null\n}\n",
    },
    .{
        .name = "--set without =",
        .args = &.{ "cfg", "--set", "server.port", "get", "name" },
        .stderr = "snek: --set expects key=value, got \"server.port\"\n" ++
            "Run 'snek cfg get --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "--set with an invalid key",
        .args = &.{ "cfg", "--set", "a..b=1", "get", "name" },
        .stderr = "snek: --set: invalid key \"a..b\"\n" ++
            "Run 'snek cfg get --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "--set crossing a scalar",
        .args = &.{ "cfg", "--set", "a=1", "--set", "a.b=2", "get", "a" },
        .stderr = "snek: --set: \"a.b\" crosses a value that is not a table\n",
        .status = 1,
    },

    // get
    .{
        .name = "get a string with spaces",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "title" },
        .stdout = "two servers\n",
    },
    .{
        .name = "get a float",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "ratio" },
        .stdout = "0.75\n",
    },
    .{
        .name = "get a bool",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "enabled" },
        .stdout = "true\n",
    },
    .{
        .name = "get an array",
        .args = &.{ "cfg", "get", "server.tags" },
        .stdout = "- a\n- b\n",
    },
    .{
        .name = "get an array element",
        .args = &.{ "cfg", "get", "server.tags.1" },
        .stdout = "b\n",
    },
    .{
        .name = "get through an array of tables",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "servers.1.host" },
        .stdout = "beta\n",
    },
    .{
        .name = "get an array of tables",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "servers" },
        .stdout = "- host: alpha\n  port: 8001\n- host: beta\n  port: 8002\n",
    },
    .{
        .name = "get an element table as TOML",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "servers.0", "-o", "toml" },
        .stdout = "host = \"alpha\"\nport = 8001\n",
    },
    .{
        .name = "get past the end of an array",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "servers.2.host" },
        .stderr = "snek: key \"servers.2.host\" is not set\n",
        .status = 1,
    },
    .{
        .name = "a table as JSON",
        .args = &.{ "cfg", "get", "server", "-o", "json" },
        .stdout =
        \\{
        \\  "host": "localhost",
        \\  "port": 8080,
        \\  "tags": [
        \\    "a",
        \\    "b"
        \\  ]
        \\}
        \\
        ,
    },
    .{
        .name = "a table as YAML",
        .args = &.{ "cfg", "get", "server", "-o", "yaml" },
        .stdout = "host: localhost\nport: 8080\ntags:\n  - a\n  - b\n",
    },
    .{
        .name = "a table as env",
        .args = &.{ "cfg", "get", "server", "-o", "env" },
        .stdout = "HOST=localhost\nPORT=8080\nTAGS=a,b\n",
    },
    .{
        .name = "a string as JSON",
        .args = &.{ "cfg", "-c", "servers.toml", "get", "title", "-o", "json" },
        .stdout = "\"two servers\"\n",
    },
    .{
        .name = "a scalar cannot be TOML",
        .args = &.{ "cfg", "get", "name", "-o", "toml" },
        .stderr = "snek: this value cannot be written as toml\n",
        .status = 1,
    },
    .{
        .name = "a scalar cannot be env",
        .args = &.{ "cfg", "get", "name", "-o", "env" },
        .stderr = "snek: this value cannot be written as env\n",
        .status = 1,
    },
    .{
        .name = "missing key",
        .args = &.{ "cfg", "get", "missing" },
        .stderr = "snek: key \"missing\" is not set\n",
        .status = 1,
    },

    .{
        .name = "get --as checks and normalizes a value",
        .args = &.{ "cfg", "get", "server.port", "--as", "int" },
        .stdout = "8080\n",
    },
    .{
        .name = "get --as fails for the wrong type",
        .args = &.{ "cfg", "get", "server.host", "--as", "int" },
        .stderr = "snek: server.host: expected an integer of type i64\n",
        .status = 1,
    },

    .{
        .name = "--log-level debug says which files were loaded",
        .args = &.{ "cfg", "-c", "snek.toml", "--log-level", "debug", "get", "server.port" },
        .stdout = "8080\n",
        .stderr = "snek: debug: loaded snek.toml\n",
    },

    // validate --schema
    .{
        .name = "validate against a schema",
        .args = &.{
            "cfg",       "validate", "--schema",   "schema.json",
            "snek.toml", "app.ini",  "extra.yaml",
        },
        .stdout = "snek.toml: ok\napp.ini: ok\n",
        .stderr = "snek: extra.yaml: name: required key is missing\n",
        .status = 1,
    },
    .{
        .name = "validate warns about plain-text secrets and deprecated keys",
        .args = &.{ "cfg", "validate", "--schema", "lint-schema.json", "lint.toml" },
        .stdout = "lint.toml: ok\n",
        .stderr =
        \\snek: warning: lint.toml:4:12: db.password: a secret in plain text (use ${secret:...})
        \\  4 | password = "hunter2"
        \\    |            ^
        \\snek: warning: lint.toml:6:12: db.old_port: deprecated: use port
        \\  6 | old_port = 5
        \\    |            ^
        \\
        ,
    },
    .{
        .name = "validate -q keeps the warnings to itself",
        .args = &.{ "cfg", "validate", "-q", "lint.toml" },
        .stdout = "lint.toml: ok\n",
    },
    .{
        .name = "validate suggests the key a typo meant",
        .args = &.{ "cfg", "validate", "--schema", "schema.json", "typo.toml" },
        .stderr =
        \\snek: warning: typo.toml:2:10: srever: unknown key; did you mean 'server'?
        \\  2 | srever = "x"
        \\    |          ^
        \\snek: typo.toml:5:8: server.prot: unknown key; did you mean 'port'?
        \\  5 | prot = 8080
        \\    |        ^
        \\
        ,
        .status = 1,
    },
    .{
        .name = "validate against a schema reports every problem",
        .args = &.{ "cfg", "validate", "--schema", "schema.json", "invalid.yaml" },
        .stderr =
        \\snek: invalid.yaml:1:7: name: must be at least 2 characters
        \\  1 | name: x
        \\    |       ^
        \\snek: invalid.yaml:3:9: server.port: must be at least 1
        \\  3 |   port: 0
        \\    |         ^
        \\snek: invalid.yaml:4:10: server.extra: unknown key
        \\  4 |   extra: 1
        \\    |          ^
        \\snek: invalid.yaml:5:9: server.tags.1: expected string, found an integer
        \\  5 |   tags: [a, 2]
        \\    |         ^
        \\
        ,
        .status = 1,
    },
    .{
        .name = "validate with no files checks the effective configuration",
        .args = &.{ "cfg", "validate", "--schema", "schema.json" },
        .stdout = "configuration: ok\n",
    },
    .{
        .name = "validate the effective configuration reports where each problem came from",
        .args = &.{
            "cfg",          "validate", "--schema", "schema.json", "-c", "invalid.yaml",
            "--env-prefix", "APP",      "--set",    "name=ok",
        },
        .env = &.{.{ "APP_SERVER_HOST", "1" }},
        .stderr =
        \\snek: invalid.yaml:3:9: server.port: must be at least 1
        \\  3 |   port: 0
        \\    |         ^
        \\snek: invalid.yaml:4:10: server.extra: unknown key
        \\  4 |   extra: 1
        \\    |          ^
        \\snek: invalid.yaml:5:9: server.tags.1: expected string, found an integer
        \\  5 |   tags: [a, 2]
        \\    |         ^
        \\
        ,
        .status = 1,
    },
    .{
        .name = "validate the effective configuration names a variable or --set",
        .args = &.{
            "cfg",   "validate", "--schema", "schema.json", "--env-prefix", "APP",
            "--set", "name=x",
        },
        .env = &.{.{ "APP_SERVER_PORT", "0" }},
        .stderr = "snek: name: must be at least 2 characters (from --set)\n" ++
            "snek: server.port: must be at least 1 (from $APP_SERVER_PORT)\n",
        .status = 1,
    },

    // redact
    .{
        .name = "redact hides secret-looking values, keeping the rest",
        .args = &.{ "cfg", "redact", "lint.toml" },
        .stdout =
        \\name = "app"
        \\
        \\[db]
        \\password = "<redacted>"
        \\token = "${secret:env:DB_TOKEN}"
        \\old_port = 5
        \\
        ,
    },
    .{
        .name = "redact standard input, and keys named with --secret",
        .args = &.{ "cfg", "redact", "-", "--from", "yaml", "--secret", "db.url" },
        .stdin = "# Bug.\nuser: ada # me\napi_key: k1\ndb:\n  url: postgres://x\n" ++
            "auth:\n  tokens: [a, b]\n",
        .stdout = "# Bug.\nuser: ada # me\napi_key: <redacted>\ndb:\n  url: <redacted>\n" ++
            "auth:\n  tokens: <redacted>\n",
    },
    .{
        .name = "redact standard input needs --from",
        .args = &.{ "cfg", "redact", "-" },
        .stdin = "",
        .stderr = "snek: reading standard input needs --from\n",
        .status = 1,
    },

    // whole-file tools
    .{
        .name = "show as a systemd drop-in",
        .args = &.{ "cfg", "show", "-o", "systemd" },
        .stdout =
        \\[Service]
        \\Environment="NAME=demo"
        \\Environment="DEBUG=false"
        \\Environment="SERVER__HOST=localhost"
        \\Environment="SERVER__PORT=8080"
        \\Environment="SERVER__TAGS=a,b"
        \\
        ,
    },
    .{
        .name = "diff two layers",
        .args = &.{ "cfg", "diff", "--layer", "default", "--layer", "override", "--set", "a=1" },
        .stdout = "+ a = 1\n",
        .status = 1,
    },
    .{
        .name = "diff needs two files or two layers",
        .args = &.{ "cfg", "diff", "snek.toml" },
        .stderr = "snek: give two files, or --layer twice\nRun 'snek cfg diff --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "schema check",
        .args = &.{ "cfg", "schema", "check", "schema.json", "snek.toml" },
        .stdout = "snek.toml: ok\n",
    },
    .{
        .name = "edit needs a terminal",
        .args = &.{ "cfg", "edit" },
        .stderr = "snek: edit needs a terminal; use \"snek cfg set\" in scripts\n" ++
            "Run 'snek cfg edit --help' for usage.\n",
        .status = 2,
    },

    // INI and JSON with comments
    .{
        .name = "reads INI",
        .args = &.{ "cfg", "-c", "app.ini", "get", "server", "-o", "json" },
        .stdout = "{\n  \"port\": \"7004\"\n}\n",
    },
    .{
        .name = "reads JSON with comments",
        .args = &.{ "cfg", "-c", "editor.jsonc", "explain" },
        .stdout =
        \\KEY          VALUE       SOURCE
        \\name         from-jsonc  file (editor.jsonc)
        \\server.port  7005        file (editor.jsonc)
        \\
        ,
    },
    .{
        .name = "converts to INI",
        .args = &.{ "cfg", "convert", "editor.jsonc", "--to", "ini" },
        .stdout = "name = from-jsonc\n\n[server]\nport = 7005\n",
    },
    // diff
    .{
        .name = "diff across formats",
        .args = &.{ "cfg", "diff", "snek.toml", "json/snek.json" },
        .stdout =
        \\- debug = false
        \\- name = demo
        \\+ name = from-json
        \\- profiles.prod.server.host = example.com
        \\- server.host = localhost
        \\- server.port = 8080
        \\+ server.port = 7002
        \\- server.tags = [a, b]
        \\
        ,
        .status = 1,
    },
    .{
        .name = "diff of identical configurations",
        .args = &.{ "cfg", "diff", "snek.toml", "snek.toml" },
        .stdout = "",
    },
    .{
        .name = "diff as JSON",
        .args = &.{ "cfg", "diff", "extra.yaml", "json/snek.json", "-o", "json" },
        .stdout =
        \\[
        \\  {
        \\    "key": "name",
        \\    "change": "added",
        \\    "old": null,
        \\    "new": "from-json"
        \\  },
        \\  {
        \\    "key": "server.port",
        \\    "change": "changed",
        \\    "old": 9090,
        \\    "new": 7002
        \\  }
        \\]
        \\
        ,
        .status = 1,
    },
    .{
        .name = "diff of a missing file",
        .args = &.{ "cfg", "diff", "snek.toml", "missing.toml" },
        .stderr = "snek: missing.toml: no such file\n",
        .status = 1,
    },

    // env
    .{
        .name = "env",
        .args = &.{ "cfg", "env" },
        .stdout =
        \\export DEBUG='false'
        \\export NAME='demo'
        \\export SERVER_HOST='localhost'
        \\export SERVER_PORT='8080'
        \\export SERVER_TAGS='a,b'
        \\
        ,
    },
    .{
        .name = "env for fish, with a prefix",
        .args = &.{ "cfg", "env", "--prefix", "app", "--shell", "fish", "--set", "name=it's" },
        .stdout =
        \\set -gx APP_DEBUG 'false'
        \\set -gx APP_NAME 'it\'s'
        \\set -gx APP_SERVER_HOST 'localhost'
        \\set -gx APP_SERVER_PORT '8080'
        \\set -gx APP_SERVER_TAGS 'a,b'
        \\
        ,
    },
    .{
        .name = "env with two keys for one name",
        .args = &.{ "cfg", "env", "--set", "server_port=1" },
        .stderr = "snek: server.port and server_port both map to SERVER_PORT\n",
        .status = 1,
    },
    .{
        .name = "env rejects an output format",
        .args = &.{ "cfg", "env", "-o", "json" },
        // Under -o json, errors are JSON too.
        .stderr = "{\"error\":\"env writes shell commands; drop -o json\",\"hint\":" ++
            "\"Run 'snek cfg env --help' for usage.\"}\n",
        .status = 2,
    },

    // keys
    .{
        .name = "keys",
        .args = &.{ "cfg", "keys" },
        .stdout = "debug\nname\nserver.host\nserver.port\nserver.tags\n",
    },
    .{
        .name = "keys under a prefix",
        .args = &.{ "cfg", "keys", "server" },
        .stdout = "server.host\nserver.port\nserver.tags\n",
    },
    .{
        .name = "keys as JSON",
        .args = &.{ "cfg", "keys", "-o", "json" },
        .stdout =
        \\[
        \\  "debug",
        \\  "name",
        \\  "server.host",
        \\  "server.port",
        \\  "server.tags"
        \\]
        \\
        ,
    },
    .{
        .name = "keys as YAML",
        .args = &.{ "cfg", "keys", "server", "-o", "yaml" },
        .stdout = "- server.host\n- server.port\n- server.tags\n",
    },

    // show
    .{
        .name = "show",
        .args = &.{ "cfg", "show" },
        .stdout = snek_toml_yaml,
    },
    .{
        .name = "show as YAML",
        .args = &.{ "cfg", "show", "-o", "yaml" },
        .stdout = snek_toml_yaml,
    },
    .{
        .name = "show as JSON",
        .args = &.{ "cfg", "show", "-o", "json" },
        .stdout = snek_toml_json,
    },
    .{
        .name = "show as env",
        .args = &.{ "cfg", "show", "-o", "env" },
        .stdout =
        \\NAME=demo
        \\DEBUG=false
        \\SERVER__HOST=localhost
        \\SERVER__PORT=8080
        \\SERVER__TAGS=a,b
        \\
        ,
    },
    .{
        .name = "show what env cannot hold",
        .args = &.{ "cfg", "-c", "servers.toml", "show", "-o", "env" },
        .stderr = "snek: the configuration cannot be written as env\n",
        .status = 1,
    },
    .{
        .name = "show an array of tables as TOML",
        .args = &.{ "cfg", "-c", "servers.toml", "show", "-o", "toml" },
        .stdout =
        \\title = "two servers"
        \\ratio = 0.75
        \\enabled = true
        \\
        \\[[servers]]
        \\host = "alpha"
        \\port = 8001
        \\
        \\[[servers]]
        \\host = "beta"
        \\port = 8002
        \\
        ,
    },
    .{
        .name = "show redacts secrets",
        .args = &.{ "cfg", "show", "-o", "toml", "--secret", "name" },
        .stdout =
        \\name = "<redacted>"
        \\debug = false
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\tags = ["a", "b"]
        \\
        ,
    },
    .{
        .name = "show redacts a nested secret",
        .args = &.{ "cfg", "show", "--secret", "server.host", "--secret", "debug" },
        .stdout =
        \\name: demo
        \\debug: <redacted>
        \\server:
        \\  host: <redacted>
        \\  port: 8080
        \\  tags:
        \\    - a
        \\    - b
        \\
        ,
    },
    .{
        .name = "show --reveal",
        .args = &.{ "cfg", "show", "--secret", "server.host", "--reveal", "-o", "json" },
        .stdout = snek_toml_json,
    },
    .{
        .name = "explain redacts secrets",
        .args = &.{
            "cfg", "explain", "server", "--secret", "server.tags", "--secret", "server.host",
        },
        .stdout =
        \\KEY          VALUE       SOURCE
        \\server.host  <redacted>  file (./snek.toml)
        \\server.port  8080        file (./snek.toml)
        \\server.tags  <redacted>  file (./snek.toml)
        \\
        ,
    },
    .{
        .name = "explain --reveal",
        .args = &.{ "cfg", "explain", "name", "--secret", "name", "--reveal" },
        .stdout =
        \\KEY   VALUE  SOURCE
        \\name  demo   file (./snek.toml)
        \\
        ,
    },
    .{
        .name = "show the default layer",
        .args = &.{ "cfg", "show", "--layer", "default", "-o", "json" },
        .stdout = "{}\n",
    },
    .{
        .name = "show the file layer",
        .args = &.{ "cfg", "-c", "snek.toml", "-c", "extra.yaml", "show", "--layer", "file" },
        .stdout =
        \\name: demo
        \\debug: false
        \\server:
        \\  host: localhost
        \\  port: 9090
        \\  tags:
        \\    - a
        \\    - b
        \\profiles:
        \\  prod:
        \\    server:
        \\      host: example.com
        \\
        ,
    },
    .{
        .name = "show the flag layer",
        .args = &.{ "cfg", "show", "--layer", "flag", "-o", "json" },
        .stdout = "{}\n",
    },
    .{
        .name = "show the override layer",
        .args = &.{ "cfg", "--set", "a.b=1", "show", "--layer", "override", "-o", "toml" },
        .stdout = "[a]\nb = 1\n",
    },
    .{
        .name = "show an unknown layer",
        .args = &.{ "cfg", "show", "--layer", "disk" },
        .stderr = "snek: invalid value \"disk\" for flag --layer: expected one of " ++
            "default, file, profile, env, flag, override\n" ++
            "Run 'snek cfg show --help' for usage.\n",
        .status = 2,
    },

    // explain
    .{
        .name = "explain names each source",
        .args = &.{
            "cfg", "explain",   "--env-prefix", "APP",
            "-c",  "snek.toml", "-c",           "extra.yaml",
        },
        .env = &.{.{ "APP_NAME", "env-name" }},
        .stdout =
        \\KEY          VALUE      SOURCE
        \\debug        false      file (snek.toml)
        \\name         env-name   env (APP_NAME)
        \\server.host  localhost  file (snek.toml)
        \\server.port  9090       file (extra.yaml)
        \\server.tags  [a, b]     file (snek.toml)
        \\
        ,
    },
    .{
        .name = "explain an override",
        .args = &.{ "cfg", "--set", "server.port=1", "explain", "server.port" },
        .stdout =
        \\KEY          VALUE  SOURCE
        \\server.port  1      override
        \\
        ,
    },
    .{
        .name = "explain with no keys under the prefix",
        .args = &.{ "cfg", "explain", "nope" },
        .stderr = "snek: no keys under \"nope\"\n",
        .status = 1,
    },
    .{
        .name = "explain as JSON keeps value types",
        .args = &.{ "cfg", "explain", "server", "-o", "json" },
        .stdout =
        \\[
        \\  {
        \\    "key": "server.host",
        \\    "value": "localhost",
        \\    "layer": "file",
        \\    "source": "./snek.toml"
        \\  },
        \\  {
        \\    "key": "server.port",
        \\    "value": 8080,
        \\    "layer": "file",
        \\    "source": "./snek.toml"
        \\  },
        \\  {
        \\    "key": "server.tags",
        \\    "value": [
        \\      "a",
        \\      "b"
        \\    ],
        \\    "layer": "file",
        \\    "source": "./snek.toml"
        \\  }
        \\]
        \\
        ,
    },
    .{
        .name = "explain as YAML",
        .args = &.{ "cfg", "--env-prefix", "APP", "explain", "name", "-o", "yaml" },
        .env = &.{.{ "APP_NAME", "env-name" }},
        .stdout = "- key: name\n  value: env-name\n  layer: env\n  source: APP_NAME\n",
    },

    // convert
    .{
        .name = "convert JSON to TOML",
        .args = &.{ "cfg", "convert", "data.json", "--to", "toml" },
        .stdout = "b = [1, 2]\n\n[a]\nx = \"y\"\n",
    },
    .{
        .name = "convert JSON to YAML",
        .args = &.{ "cfg", "convert", "data.json", "--to", "yaml" },
        .stdout = "b:\n  - 1\n  - 2\na:\n  x: y\n",
    },
    .{
        .name = "convert TOML to JSON",
        .args = &.{ "cfg", "convert", "servers.toml", "--to", "json" },
        .stdout =
        \\{
        \\  "title": "two servers",
        \\  "ratio": 0.75,
        \\  "enabled": true,
        \\  "servers": [
        \\    {
        \\      "host": "alpha",
        \\      "port": 8001
        \\    },
        \\    {
        \\      "host": "beta",
        \\      "port": 8002
        \\    }
        \\  ]
        \\}
        \\
        ,
    },
    .{
        .name = "convert TOML to YAML",
        .args = &.{ "cfg", "convert", "snek.toml", "-t", "yaml" },
        .stdout = snek_toml_yaml ++ "profiles:\n  prod:\n    server:\n      host: example.com\n",
    },
    .{
        .name = "convert YAML to TOML",
        .args = &.{ "cfg", "convert", "extra.yaml", "--to", "toml" },
        .stdout = "[server]\nport = 9090\n",
    },
    .{
        .name = "convert YAML to env",
        .args = &.{ "cfg", "convert", "extra.yaml", "--to", "env" },
        .stdout = "SERVER__PORT=9090\n",
    },
    .{
        .name = "convert env to JSON",
        .args = &.{ "cfg", "convert", "app.env", "--to", "json" },
        .stdout = "{\n  \"app_name\": \"demo\",\n  \"server\": {\n    \"port\": \"80\"\n  }\n}\n",
    },
    .{
        .name = "convert env to YAML",
        .args = &.{ "cfg", "convert", "app.env", "--to", "yaml" },
        .stdout = "app_name: demo\nserver:\n  port: \"80\"\n",
    },
    .{
        .name = "convert TOML to env",
        .args = &.{ "cfg", "convert", "snek.toml", "--to", "env" },
        .stdout =
        \\NAME=demo
        \\DEBUG=false
        \\SERVER__HOST=localhost
        \\SERVER__PORT=8080
        \\SERVER__TAGS=a,b
        \\PROFILES__PROD__SERVER__HOST=example.com
        \\
        ,
    },
    .{
        .name = "convert standard input",
        .args = &.{ "cfg", "convert", "-", "--from", "yaml", "--to", "json" },
        .stdin = "a:\n  b: [1, true]\n",
        .stdout = "{\n  \"a\": {\n    \"b\": [\n      1,\n      true\n    ]\n  }\n}\n",
    },
    .{
        .name = "convert standard input as env",
        .args = &.{ "cfg", "convert", "-", "-f", "env", "-t", "toml" },
        .stdin = "A__B=1\n",
        .stdout = "[a]\nb = \"1\"\n",
    },
    .{
        .name = "convert standard input without --from",
        // No input: snek fails before reading it, and writing it would race the exit.
        .args = &.{ "cfg", "convert", "-", "--to", "json" },
        .stderr = "snek: reading standard input needs --from\n",
        .status = 1,
    },
    .{
        .name = "convert an unknown extension",
        .args = &.{ "cfg", "convert", "notes.txt", "--to", "json" },
        .stderr = "snek: notes.txt: unknown format; pass --from\n",
        .status = 1,
    },
    .{
        .name = "convert an unknown extension with --from",
        .args = &.{ "cfg", "convert", "notes.txt", "--from", "toml", "--to", "json" },
        .stdout = "{\n  \"a\": 1\n}\n",
    },
    .{
        .name = "convert to an unknown format",
        .args = &.{ "cfg", "convert", "data.json", "--to", "xml" },
        .stderr = "snek: invalid value \"xml\" for flag --to: expected one of " ++
            "json, yaml, toml, zon, env, jsonc, ini\n" ++
            "Run 'snek cfg convert --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "convert without --to",
        .args = &.{ "cfg", "convert", "data.json" },
        .stderr = "snek: required flag --to is not set\n" ++
            "Run 'snek cfg convert --help' for usage.\n",
        .status = 2,
    },

    // validate and fmt
    .{
        .name = "validate every format",
        .args = &.{
            "cfg",       "validate", "snek.toml",      "extra.yaml",
            "data.json", "app.env",  "yaml/snek.yaml", "json/snek.json",
        },
        .stdout =
        \\snek.toml: ok
        \\extra.yaml: ok
        \\data.json: ok
        \\app.env: ok
        \\yaml/snek.yaml: ok
        \\json/snek.json: ok
        \\
        ,
    },
    .{
        .name = "validate reports positions",
        .args = &.{ "cfg", "validate", "bad.json", "data.json" },
        .stdout = "data.json: ok\n",
        .stderr = "snek: bad.json:1:9: invalid JSON\n",
        .status = 1,
    },
    .{
        .name = "validate reports every invalid file",
        .args = &.{
            "cfg",       "validate", "bad.toml",     "bad.yaml", "servers.toml",
            "notes.txt", "bad.json", "missing.toml",
        },
        .stdout = "servers.toml: ok\n",
        .stderr =
        \\snek: bad.toml:2:5: expected a value
        \\snek: bad.yaml:3:2: inconsistent indentation
        \\snek: notes.txt: unknown format (use .toml, .yaml, .json, .jsonc, .zon, .env, or .ini)
        \\snek: bad.json:1:9: invalid JSON
        \\snek: missing.toml: no such file
        \\
        ,
        .status = 1,
    },
    .{
        .name = "fmt --check lists unformatted files",
        .args = &.{ "cfg", "fmt", "--check", "data.json" },
        .stdout = "data.json\n",
        .status = 1,
    },
    .{
        .name = "fmt --check passes formatted files",
        .args = &.{ "cfg", "fmt", "--check", "servers.toml", "extra.yaml", "app.env" },
    },
    .{
        .name = "fmt --check an unknown format",
        .args = &.{ "cfg", "fmt", "--check", "notes.txt" },
        .stderr = "snek: notes.txt: " ++ unknown_format ++ "\n",
        .status = 1,
    },

    // set and unset that fail before touching a file
    .{
        .name = "set with an unknown extension",
        .args = &.{ "cfg", "set", "a", "1", "-c", "notes.txt" },
        .stderr = "snek: notes.txt: " ++ unknown_format ++ "\n",
        .status = 1,
    },
    .{
        .name = "set with no file to edit",
        .args = &.{ "cfg", "set", "a", "1" },
        .cwd = "..", // test/, which has no snek.* file

        .stderr = "snek: no config file found; pass --config <path>\n",
        .status = 1,
    },
    .{
        .name = "unset in a missing file",
        .args = &.{ "cfg", "unset", "a", "-c", "missing.toml" },
        .stderr = "snek: missing.toml: no such file\n",
        .status = 1,
    },
    .{
        .name = "set into a file with a syntax error",
        .args = &.{ "cfg", "set", "a", "1", "-c", "bad.toml" },
        .stderr = "snek: bad.toml:2:5: expected a value\n",
        .status = 1,
    },
    .{
        .name = "set needs a value",
        .args = &.{ "cfg", "set", "a" },
        .stderr = "snek: \"snek cfg set\" requires at least 2 arguments, received 1\n" ++
            "Run 'snek cfg set --help' for usage.\n",
        .status = 2,
    },

    // Usage errors
    .{
        .name = "unknown command suggests",
        .args = &.{ "cfg", "gte" },
        .stderr = "snek: unknown command \"gte\" for \"snek cfg\"\nDid you mean \"get\"?\n" ++
            "Run 'snek cfg --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "invalid enum flag",
        .args = &.{ "cfg", "get", "name", "-o", "xml" },
        .stderr = "snek: invalid value \"xml\" for flag --output: expected one of " ++
            "text, json, yaml, toml, zon, env, ini, systemd\n" ++
            "Run 'snek cfg get --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "missing argument",
        .args = &.{ "cfg", "get" },
        .stderr = "snek: \"snek cfg get\" requires at least 1 argument, received 0\n" ++
            "Run 'snek cfg get --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "unknown group suggests",
        .args = &.{"cgf"},
        .stderr = "snek: unknown command \"cgf\" for \"snek\"\nDid you mean \"cfg\"?\n" ++
            "Run 'snek --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "cfg alias",
        .args = &.{ "config", "get", "name" },
        .stdout = "demo\n",
    },

    // cli
    .{
        .name = "cli docs as Markdown",
        .args = &.{ "cli", "docs" },
        .stdout_contains = "## snek cfg get\n\n" ++
            "Print the effective value of a key. Scalars print bare; tables and arrays " ++
            "print in\nthe --output format (YAML for text).\n\n```\n" ++ get_usage ++ "```\n",
    },
    .{
        .name = "cli docs as Markdown lists commands",
        .args = &.{ "cli", "docs", "--format", "markdown" },
        .stdout_contains = "| `cfg` | Query, explain, edit, and convert configuration |\n",
    },
    .{
        .name = "cli docs as a man page",
        .args = &.{ "cli", "docs", "--format", "man" },
        .stdout_contains = ".TH SNEK 1\n.SH NAME\n" ++
            "snek \\- Configuration tooling, built with the snek cli and cfg libraries\n",
    },
    .{
        .name = "cli docs as a man page has a section per command",
        .args = &.{ "cli", "docs", "-f", "man" },
        .stdout_contains = ".SS \"snek cfg convert\"\n",
    },
    .{
        .name = "cli docs in an unknown format",
        .args = &.{ "cli", "docs", "--format", "pdf" },
        .stderr = "snek: invalid value \"pdf\" for flag --format: expected one of " ++
            "markdown, man, html, json\nRun 'snek cli docs --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "cli docs as JSON",
        .args = &.{ "cli", "docs", "--format", "json" },
        .stdout_contains = "{\n  \"name\": \"snek\",\n  \"path\": \"snek\",",
    },
    .{
        .name = "cli docs as JSON: a flag object, every key",
        .args = &.{ "cli", "docs", "--format", "json" },
        .stdout_contains =
        \\            {
        \\              "name": "default",
        \\              "short": null,
        \\              "help": "Print this instead of failing when the key is unset",
        \\              "kind": "value",
        \\              "type": "string",
        \\              "label": "value",
        \\              "choices": [],
        \\              "default": null,
        \\              "env": null,
        \\              "required": false,
        \\              "repeatable": false,
        \\              "persistent": false,
        \\              "inherited": false,
        \\              "deprecated": null,
        \\              "aliases": [],
        \\              "minimum": null,
        \\              "maximum": null
        \\            },
        ,
    },
    .{
        .name = "cli docs as HTML",
        .args = &.{ "cli", "docs", "--format", "html" },
        .stdout_contains = "<section id=\"snek-cfg-get\">\n<h2>snek cfg get</h2>",
    },
    .{
        .name = "cli docs as a man page lists exit statuses",
        .args = &.{ "cli", "docs", "-f", "man" },
        .stdout_contains = ".SH EXIT STATUS\n.TP\n\\fB0\\fR\nSuccess\n.TP\n\\fB1\\fR\n" ++
            "The command failed\n.TP\n\\fB2\\fR\n",
    },
    .{
        .name = "cli docs as Markdown lists exit statuses, plugins' 126 among them",
        .args = &.{ "cli", "docs" },
        .stdout_contains = "| `126` | A plugin was found but could not be started |\n",
    },
    .{
        .name = "--color always colors help on a pipe",
        .args = &.{ "version", "--help", "--color", "always" },
        .stdout_contains = "\x1b[1;35mUsage:\x1b[0m\n",
    },
    .{
        .name = "--color never wins over FORCE_COLOR",
        .args = &.{ "--color=never", "version", "--help" },
        .env = &.{.{ "FORCE_COLOR", "1" }},
        .stdout_contains = "information\n\nUsage:\n  snek version",
    },
    .{
        .name = "cli explain -o jsonl: one object per line",
        .args = &.{ "cli", "explain", "-o", "jsonl" },
        .stdin = "\x1b[1mhi",
        .stdout = "{\"kind\":\"sequence\",\"raw\":\"\\u001b[1m\"," ++
            "\"description\":\"SGR: bold\"}\n" ++
            "{\"kind\":\"text\",\"raw\":\"hi\",\"description\":\"hi\"}\n",
    },
    .{
        .name = "cli docs --dir needs the man format",
        .args = &.{ "cli", "docs", "--dir", "out" },
        .stderr = "snek: --dir applies to --format man\nRun 'snek cli docs --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "cli repl runs a script",
        .args = &.{ "cli", "repl" },
        .stdin = "cfg get name\n\ncfg get server.port --default 1\ncfg get nope\nexit\ncfg keys\n",
        .stdout = "demo\n8080\n",
        .stderr = "snek: key \"nope\" is not set\n",
        .status = 1,
    },
    .{
        .name = "cli docs as JSON lists nested commands",
        .args = &.{ "cli", "docs", "--format", "json" },
        .stdout_contains = "\"path\": \"snek cli add\"",
    },
    .{
        .name = "cli init with an invalid name",
        .args = &.{ "cli", "init", "Demo" },
        .stderr = "snek: invalid name \"Demo\": use at most 32 lowercase letters, digits, _ " ++
            "and -, starting with a letter, and not a Zig keyword\n" ++
            "Run 'snek cli init --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "cli init with two dependencies",
        .args = &.{ "cli", "init", "y", "--module-path", "a", "--fetch", "b" },
        .stderr = "snek: flags --module-path and --fetch cannot be used together\n" ++
            "Run 'snek cli init --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "bash completion script",
        .args = &.{ "cli", "completion", "bash" },
        .stdout_contains = "#   source <(snek cli completion bash)\n",
    },
    .{
        .name = "zsh completion script",
        .args = &.{ "cli", "completion", "zsh" },
        .stdout_contains = "#   source <(snek cli completion zsh)\n",
    },
    .{
        .name = "fish completion script",
        .args = &.{ "cli", "completion", "fish" },
        .stdout_contains = "#   snek cli completion fish | source\n",
    },
    .{
        .name = "powershell completion script",
        .args = &.{ "cli", "completion", "powershell" },
        .stdout_contains = "#   snek cli completion powershell | Out-String | " ++
            "Invoke-Expression\n",
    },
    .{
        .name = "completion for an unknown shell",
        .args = &.{ "cli", "completion", "tcsh" },
        .stderr = "snek: unknown command \"tcsh\" for \"snek cli completion\"\n" ++
            "Run 'snek cli completion --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "completion is not a root command",
        .args = &.{ "completion", "bash" },
        .stderr = "snek: unknown command \"completion\" for \"snek\"\n" ++
            "Run 'snek --help' for usage.\n",
        .status = 2,
    },

    // version and help
    .{
        .name = "version command",
        .args = &.{"version"},
        .stdout_contains = "snek " ++ version ++ "\nzig 0.17.0, ",
    },
    .{
        .name = "show --layer env shows what the environment supplied",
        .args = &.{ "cfg", "--env-prefix", "APP", "show", "--layer", "env", "-o", "json" },
        .env = &.{.{ "APP_NAME", "from-env" }},
        .stdout = "{\n  \"name\": \"from-env\"\n}\n",
    },
    .{
        .name = "show --layer profile shows the active profile",
        .args = &.{ "cfg", "--profile", "prod", "show", "--layer", "profile", "-o", "json" },
        .stdout = "{\n  \"server\": {\n    \"host\": \"example.com\"\n  }\n}\n",
    },
    .{
        .name = "discovers snek.zon",
        .cwd = "zon",
        .args = &.{ "cfg", "get", "server.port" },
        .stdout = "7070\n",
    },
    .{
        .name = "convert JSON to ZON",
        .args = &.{ "cfg", "convert", "data.json", "--to", "zon" },
        .stdout = ".{\n    .b = .{ 1, 2 },\n    .a = .{\n        .x = \"y\",\n    },\n}\n",
    },
    .{
        .name = "show as ZON",
        .cwd = "zon",
        .args = &.{ "cfg", "show", "-o", "zon" },
        .stdout = ".{\n    .name = \"zon-demo\",\n" ++
            "    .server = .{\n        .port = 7070,\n    },\n}\n",
    },
    .{
        .name = "keys -0 separates with NUL",
        .args = &.{ "cfg", "keys", "server", "-0" },
        .stdout = "server.host\x00server.port\x00server.tags\x00",
    },
    .{
        .name = "keys --null rejects structured output",
        .args = &.{ "cfg", "keys", "--null", "-o", "json" },
        .stderr = "{\"error\":\"--null applies to text output; drop -o json\",\"hint\":" ++
            "\"Run 'snek cfg keys --help' for usage.\"}\n",
        .status = 2,
    },
    .{
        .name = "get --default when the key is unset",
        .args = &.{ "cfg", "get", "missing", "--default", "8080", "-o", "json" },
        .stdout = "8080\n",
    },
    .{
        .name = "get --default is ignored when the key is set",
        .args = &.{ "cfg", "get", "name", "--default", "other" },
        .stdout = "demo\n",
    },
    .{
        .name = "get --raw strips JSON quoting",
        .args = &.{ "cfg", "get", "name", "-o", "json", "--raw" },
        .stdout = "demo\n",
    },
    .{
        .name = "get --raw keeps tables structured",
        .args = &.{ "cfg", "get", "server", "-o", "json", "--raw" },
        .stdout_contains = "{\n  \"host\": \"localhost\",",
    },
    .{
        .name = "fmt --check -0",
        .args = &.{ "cfg", "fmt", "--check", "-0", "data.json" },
        .stdout = "data.json\x00",
        .status = 1,
    },
    .{
        .name = "-q is accepted anywhere",
        .args = &.{ "-q", "cfg", "get", "name", "--quiet" },
        .stdout = "demo\n",
    },
    .{
        .name = "version flag",
        .args = &.{"--version"},
        .stdout = "snek " ++ version ++ "\n",
    },
    .{
        .name = "no arguments print help",
        .args = &.{},
        .stdout_contains = "Usage:\n  snek <command>\n\nCommands:\n" ++
            "  cfg        Query, explain, edit, and convert configuration\n",
    },
    .{
        .name = "help flag",
        .args = &.{"--help"},
        .stdout_contains = "Use \"snek <command> --help\" for more information about a command.\n",
    },
    .{
        .name = "cfg alone prints its help",
        .args = &.{"cfg"},
        .stdout_contains = "Aliases:\n  cfg, config\n\nQuery Commands:\n" ++
            "  get        Print one value\n",
    },
    .{
        .name = "help for a command",
        .args = &.{ "help", "cfg", "get" },
        .stdout_contains = get_usage,
    },
    .{
        .name = "--help for a command",
        .args = &.{ "cfg", "get", "--help" },
        .stdout_contains = get_usage,
    },
    .{
        .name = "help for an unknown command",
        .args = &.{ "help", "cfg", "nope" },
        .stderr = "snek: unknown command \"nope\" for \"snek cfg\"\n" ++
            "Run 'snek cfg --help' for usage.\n",
        .status = 2,
    },

    // platform
    .{
        .name = "platform dirs on any OS",
        .args = &.{ "platform", "dirs", "myapp", "-o", "json" },
        .env = &.{ .{ "HOME", "/home/ann" }, .{ "USERPROFILE", "C:\\Users\\ann" } },
        .stdout_contains = "{\n  \"app\": \"myapp\",\n  \"os\": \"" ++ @tagName(builtin.os.tag) ++
            "\",\n  \"config\": ",
    },
    .{
        .name = "platform dirs without a home directory",
        .args = &.{ "platform", "dirs" },
        .stderr = "snek: no home directory: set " ++
            (if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") ++
            " to an absolute path\n",
        .status = 1,
    },
    .{
        .name = "platform dirs with a path for a name",
        .args = &.{ "platform", "dirs", "a/b" },
        .stderr = "snek: invalid app name \"a/b\": it names a directory, so it cannot be " ++
            "empty, . or .., or hold / or \\\nRun 'snek platform dirs --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "platform info as JSON",
        .args = &.{ "platform", "info", "-o", "json" },
        .stdin = "",
        .stdout_contains = "{\n  \"os\": \"" ++ @tagName(builtin.os.tag) ++
            "\",\n  \"arch\": \"" ++ @tagName(builtin.cpu.arch) ++
            "\",\n  \"zig\": \"" ++ builtin.zig_version_string ++
            "\",\n  \"snek\": \"" ++ version ++ "\",\n  \"ci\": null,\n  \"stdin_tty\": false,\n" ++
            "  \"stdout_tty\": false,\n  \"elevated\": ",
    },
    .{
        .name = "platform info names the CI service",
        .args = &.{ "platform", "info", "-o", "json" },
        .env = &.{ .{ "CI", "true" }, .{ "GITHUB_ACTIONS", "true" } },
        .stdout_contains = "  \"ci\": \"github_actions\",\n",
    },
    .{
        .name = "platform info as text",
        .args = &.{ "platform", "info" },
        .stdin = "",
        .stdout_contains = "snek        " ++ version ++ "\nci          none\nstdin_tty   no\nstdout_tty  no\n",
    },
    .{
        // Refused before any network access: the suite never touches the network.
        .name = "platform update never prompts without a terminal",
        .args = &.{ "platform", "update" },
        .stdin = "",
        .stderr = "snek: \"snek platform update\" asks for confirmation; run it at a " ++
            "terminal or pass --yes\n",
        .status = 1,
    },
    .{
        .name = "platform dirs reports errors as JSON under -o json",
        .args = &.{ "platform", "dirs", "a/b", "-o", "json" },
        .stderr = "{\"error\":\"invalid app name \\\"a/b\\\": it names a directory, so it " ++
            "cannot be empty, . or .., or hold / or \\\\\",\"hint\":\"Run 'snek platform " ++
            "dirs --help' for usage.\"}\n",
        .status = 2,
    },
    .{
        .name = "platform dirs reports a usage error the parser finds as JSON under -o json",
        .args = &.{ "platform", "dirs", "-o", "json", "--bogus" },
        .stderr = "{\"error\":\"unknown flag: --bogus\",\"hint\":\"Run 'snek platform " ++
            "dirs --help' for usage.\"}\n",
        .status = 2,
    },
    .{
        .name = "platform webauthn get needs the origin",
        .args = &.{ "platform", "webauthn", "get" },
        .stdin = "{}",
        .stderr = "snek: required flag --origin is not set\n" ++
            "Run 'snek platform webauthn get --help' for usage.\n",
        .status = 2,
    },
    .{
        .name = "platform webauthn get refuses options that are not JSON",
        .args = &.{ "platform", "webauthn", "get", "--origin", "https://example.com" },
        .stdin = "not json",
        .stderr = "snek: the options are not a JSON object\n",
        .status = 1,
    },
    .{
        .name = "platform webauthn create refuses options without the user",
        .args = &.{ "platform", "webauthn", "create", "--origin", "https://example.com" },
        .stdin = "{\"rp\":{\"name\":\"x\"},\"challenge\":\"AA\"}",
        .stderr = "snek: the options lack a required field\n",
        .status = 1,
    },

    // __complete, what the shell scripts call
    .{
        .name = "completion of root commands",
        .args = &.{ "__complete", "" },
        .stdout = "cfg\tQuery, explain, edit, and convert configuration\n" ++
            "cli\tGenerate cli applications; documentation and completion for snek\n" ++
            "platform\tDirectories, system information, self-update, releases, SSH keys, " ++
            "and WebAuthn\n" ++
            "tui\tTerminal widgets for scripts, and components to copy into your project\n" ++
            "version\tPrint version information\n" ++
            "help\tHelp about any command\n",
    },
    .{
        .name = "completion of keys",
        .args = &.{ "__complete", "cfg", "get", "server." },
        .stdout = "server.host\nserver.port\nserver.tags\n",
    },
    .{
        .name = "completion of keys reads -c and --set",
        .args = &.{ "__complete", "cfg", "get", "-c", "json/snek.json", "--set", "x=1", "" },
        .stdout = "name\nserver.port\nx\n",
    },
    .{
        .name = "completion of keys only for the first argument",
        .args = &.{ "__complete", "cfg", "get", "name", "" },
        .stdout = "",
    },
    .{
        .name = "completion of keys of a broken file offers nothing",
        .args = &.{ "__complete", "cfg", "get", "-c", "bad.toml", "" },
        .stdout = "",
    },
    .{
        .name = "completion of profiles",
        .args = &.{ "__complete", "cfg", "show", "--profile", "" },
        .stdout = "prod\n",
    },
    .{
        .name = "completion of profiles, with a missing one in the environment",
        .args = &.{ "__complete", "cfg", "show", "--profile=p" },
        .env = &.{.{ "SNEK_PROFILE", "nope" }},
        .stdout = "--profile=prod\n",
    },
    .{
        .name = "completion of cfg subcommands",
        .args = &.{ "__complete", "cfg", "" },
        .stdout = cfg_subcommands,
    },
    .{
        .name = "completion through the alias",
        .args = &.{ "__complete", "config", "" },
        .stdout = cfg_subcommands,
    },
    .{
        .name = "completion candidates",
        .args = &.{ "__complete", "cfg", "ex" },
        .stdout = "explain\tShow where each value comes from\n",
    },
    .{
        .name = "completion of flags",
        .args = &.{ "__complete", "cfg", "get", "--" },
        .stdout = "--default\tPrint this instead of failing when the key is unset\n" ++
            "--raw\tPrint a scalar bare, without the output format's quoting\n" ++
            "--as\tFail unless the value is one of these, and print it as one\n" ++
            "--config\tConfig file to load; repeatable, later files win " ++
            "(default: discover snek.*)\n" ++
            "--profile\tApply the profiles.<name> section\n" ++
            "--env-prefix\tRead key a.b from the variable <PREFIX>_A_B\n" ++
            "--set\tOverride a value; repeatable\n" ++
            "--output\tOutput format\n" ++
            "--verbose\tLog more: -v info, -vv debug, -vvv trace\n" ++
            "--log-level\tThe least severe log messages to show\n" ++
            "--color\tWhen to use color\n" ++
            "--help\tShow help\n" ++
            "--quiet\tSuppress warnings\n",
    },
    .{
        .name = "completion of --color",
        .args = &.{ "__complete", "--color", "" },
        .stdout = "auto\nalways\nnever\n",
    },
    .{
        .name = "completion of enum values",
        .args = &.{ "__complete", "cfg", "get", "-o", "" },
        .stdout = "text\njson\nyaml\ntoml\nzon\nenv\nini\nsystemd\n",
    },
    .{
        .name = "completion of a partial enum value",
        .args = &.{ "__complete", "cfg", "get", "-o", "y" },
        .stdout = "yaml\n",
    },
    .{
        .name = "completion of convert formats",
        .args = &.{ "__complete", "cfg", "convert", "--to", "" },
        .stdout = "json\nyaml\ntoml\nzon\nenv\njsonc\nini\n",
    },
    .{
        .name = "completion of shells",
        .args = &.{ "__complete", "cli", "completion", "" },
        .stdout = "bash\tPrint the bash completion script\n" ++
            "zsh\tPrint the zsh completion script\n" ++
            "fish\tPrint the fish completion script\n" ++
            "powershell\tPrint the powershell completion script\n" ++
            "install\tInstall the completion script for your shell\n",
    },
};

/// Cases whose output follows the XDG conventions, which only Linux uses by default.
const linux_cases = [_]Case{
    .{
        .name = "platform dirs on Linux",
        .args = &.{ "platform", "dirs" },
        .env = &.{
            .{ "HOME", "/home/ann" },
            .{ "XDG_CONFIG_HOME", "/xdg/config" },
            .{ "XDG_RUNTIME_DIR", "/run/user/1000" },
        },
        .stdout =
        \\config   /xdg/config/snek
        \\cache    /home/ann/.cache/snek
        \\data     /home/ann/.local/share/snek
        \\state    /home/ann/.local/state/snek
        \\runtime  /run/user/1000/snek
        \\
        ,
    },
    .{
        .name = "platform dirs on Linux as JSON",
        .args = &.{ "platform", "dirs", "myapp", "-o", "json" },
        .env = &.{ .{ "HOME", "/home/ann" }, .{ "XDG_CACHE_HOME", "relative/is/ignored" } },
        .stdout =
        \\{
        \\  "app": "myapp",
        \\  "os": "linux",
        \\  "config": "/home/ann/.config/myapp",
        \\  "cache": "/home/ann/.cache/myapp",
        \\  "data": "/home/ann/.local/share/myapp",
        \\  "state": "/home/ann/.local/state/myapp",
        \\  "runtime": null
        \\}
        \\
        ,
    },
    .{
        .name = "platform dirs --search on Linux",
        .args = &.{ "platform", "dirs", "--search" },
        .env = &.{ .{ "HOME", "/home/ann" }, .{ "XDG_CONFIG_DIRS", "/etc/a:relative:/etc/b" } },
        .stdout = "/home/ann/.config/snek\n/etc/a/snek\n/etc/b/snek\n",
    },
    .{
        .name = "platform dirs --search on Linux as JSON",
        .args = &.{ "platform", "dirs", "--search", "-o", "json" },
        .env = &.{.{ "HOME", "/home/ann" }},
        .stdout =
        \\{
        \\  "app": "snek",
        \\  "os": "linux",
        \\  "search": [
        \\    "/home/ann/.config/snek",
        \\    "/etc/xdg/snek"
        \\  ]
        \\}
        \\
        ,
    },
};

/// Cases naming POSIX paths.
const posix_cases = [_]Case{
    .{
        .name = "cli add outside a project",
        .args = &.{ "cli", "add", "-C", "/tmp", "x" },
        .stderr = "snek: /tmp/src/main.zig: not found (is /tmp a project made by snek cli " ++
            "init?)\n",
        .status = 1,
    },
};

pub fn addCases(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    for (cases) |case| addCase(b, exe, step, case);
    if (builtin.os.tag == .linux) for (linux_cases) |case| addCase(b, exe, step, case);
    if (builtin.os.tag != .windows) for (posix_cases) |case| addCase(b, exe, step, case);
    addEditCase(b, exe, step);
    addEditChains(b, exe, step);
    addEncryptChain(b, exe, step);
    addProjectChains(b, exe, step);
    addShellCompletion(b, exe, step);
}

fn addCase(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step, case: Case) void {
    const run = b.addRunArtifact(exe);
    run.setName(b.fmt("e2e: {s}", .{case.name}));
    run.setCwd(b.path(b.pathJoin(&.{ "test/fixtures", case.cwd })));
    run.clearEnvironment();
    for (case.env) |pair| run.setEnvironmentVariable(pair[0], pair[1]);
    if (case.stdin) |bytes| run.setStdIn(.{ .bytes = bytes });
    run.addArgs(case.args);
    if (case.stdout_contains) |part| {
        run.expectStdOutMatch(part);
    } else {
        run.expectStdOutEqual(case.stdout orelse "");
    }
    run.expectStdErrEqual(case.stderr orelse "");
    run.expectExitCode(case.status);
    step.dependOn(&run.step);
}

/// `set`, `set`, `unset`, then `keys`, on a file the first `set` creates. The file lives
/// in the first run's output directory, which is keyed on the binary too, so a rebuilt
/// binary starts from a fresh file instead of one an earlier build already edited.
fn addEditCase(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    const create = editRun(b, exe, "e2e: set creates the file", &.{ "set", "server.port", "9999" });
    const file = create.addPrefixedOutputFileArg("--config=", "edit.toml");

    const add = editRun(b, exe, "e2e: set adds a key", &.{ "set", "server.debug", "true" });
    add.addPrefixedFileArg("--config=", file);
    add.step.dependOn(&create.step);

    const remove = editRun(b, exe, "e2e: unset removes it", &.{ "unset", "server.debug" });
    remove.addPrefixedFileArg("--config=", file);
    remove.step.dependOn(&add.step);

    const check = editRun(b, exe, "e2e: edits are visible", &.{ "get", "server", "-o", "json" });
    check.addPrefixedFileArg("--config=", file);
    check.expectStdOutEqual("{\n  \"port\": 9999\n}\n");
    check.step.dependOn(&remove.step);
    step.dependOn(&check.step);
}

fn editRun(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    name: []const u8,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setName(name);
    run.clearEnvironment();
    run.addArg("cfg");
    run.addArgs(args);
    run.expectStdOutEqual("");
    run.expectStdErrEqual("");
    run.expectExitCode(0);
    return run;
}

/// A file, seeded from a key of `test/fixtures/seeds.toml`, then changed by `steps` in
/// order, each run in the file's directory with `-c <file>` appended. `content` is what
/// the file holds at the end.
const EditChain = struct {
    name: []const u8,
    /// The key in `seeds.toml`; unique per chain, so each chain gets its own file.
    seed: []const u8,
    file: []const u8,
    steps: []const EditStep,
    content: []const u8,
};

const EditStep = struct {
    args: []const []const u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    status: u8 = 0,
};

const edit_chains = [_]EditChain{
    .{
        .name = "profile use records the default profile, and --clear removes it",
        .seed = "profiled",
        .file = "profiled.toml",
        .steps = &.{
            .{ .args = &.{ "profile", "list" }, .stdout = "  prod\n" },
            .{ .args = &.{ "profile", "use", "prod" } },
            .{ .args = &.{ "profile", "list" }, .stdout = "* prod\n" },
            .{ .args = &.{ "get", "server.host" }, .stdout = "example.com\n" },
            .{
                .args = &.{ "profile", "use", "nope" },
                .stderr = "snek: no profile \"nope\" in the loaded files\n",
                .status = 1,
            },
            .{ .args = &.{ "profile", "use", "--clear" } },
            .{ .args = &.{ "get", "server.host" }, .stdout = "localhost\n" },
        },
        .content =
        \\[server]
        \\host = "localhost"
        \\
        \\[profiles.prod.server]
        \\host = "example.com"
        \\
        \\
        ,
    },
    .{
        .name = "fmt --sort sorts every table",
        .seed = "unsorted",
        .file = "unsorted.toml",
        .steps = &.{.{ .args = &.{ "fmt", "--sort" } }},
        .content = "a = 2\nb = 1\n\n[z]\nx = 2\ny = 1\n",
    },
    .{
        .name = "fmt --sort keeps TOML comments with their keys",
        .seed = "sort_commented",
        .file = "sort_commented.toml",
        .steps = &.{.{ .args = &.{ "fmt", "--sort" } }},
        .content =
        \\# Settings.
        \\# About alpha.
        \\alpha = 2
        \\zeta = 1 # last
        \\
        \\[server]
        \\# The host.
        \\host = "h"
        \\port = 1
        \\
        ,
    },
    .{
        .name = "unset takes the comments directly above along",
        .seed = "unset_commented",
        .file = "unset_commented.toml",
        .steps = &.{
            .{ .args = &.{ "unset", "server.port" } },
            .{ .args = &.{ "get", "server.host" }, .stdout = "h\n" },
            .{ .args = &.{ "unset", "server" } },
        },
        .content = "name = \"demo\"\n",
    },
    .{
        .name = "set and unset keep comments",
        .seed = "commented",
        .file = "commented.toml",
        .steps = &.{
            .{ .args = &.{ "set", "name", "x" } },
            .{ .args = &.{ "set", "server.port", "2" } },
            .{ .args = &.{ "set", "server.host", "h" } },
            .{ .args = &.{ "unset", "server.port" } },
        },
        .content =
        \\# A comment that set keeps.
        \\name = "x" # and this one
        \\
        \\[server]
        \\host = "h"
        \\
        ,
    },
    .{
        .name = "set keeps YAML comments",
        .seed = "yaml_commented",
        .file = "commented.yaml",
        .steps = &.{.{ .args = &.{ "set", "port", "2" } }},
        .content = "# A comment that set keeps.\nport: 2\n",
    },
    .{
        .name = "set keeps ZON comments",
        .seed = "zon_commented",
        .file = "commented.zon",
        .steps = &.{
            .{ .args = &.{ "set", "port", "2" } },
            .{ .args = &.{ "set", "host", "h" } },
        },
        .content = "// A comment that set keeps.\n.{ .port = 2, .host = \"h\" }\n",
    },
    .{
        .name = "set keeps JSON comments",
        .seed = "jsonc_commented",
        .file = "commented.jsonc",
        .steps = &.{.{ .args = &.{ "set", "port", "2" } }},
        .content = "// A comment that set keeps.\n{\"port\": 2}\n",
    },
    .{
        .name = "set warns that comments are dropped",
        .seed = "jsonc_array",
        .file = "array.jsonc",
        .steps = &.{.{
            .args = &.{ "set", "ports.0", "2" },
            .stderr = "snek: warning: array.jsonc: comments are not preserved\n",
        }},
        .content = "{\n  \"ports\": [\n    2\n  ]\n}\n",
    },
    .{
        .name = "-q silences the comments warning",
        .seed = "jsonc_array",
        .file = "quiet.jsonc",
        .steps = &.{.{ .args = &.{ "-q", "set", "ports.0", "2" } }},
        .content = "{\n  \"ports\": [\n    2\n  ]\n}\n",
    },
    .{
        .name = "set infers types",
        .seed = "typed",
        .file = "typed.toml",
        .steps = &.{
            .{ .args = &.{ "set", "version", "1.10", "--string" } },
            .{ .args = &.{ "set", "ratio", "1.5" } },
            .{ .args = &.{ "set", "on", "true" } },
            .{ .args = &.{ "set", "-s", "off", "false" } },
            .{ .args = &.{ "rm", "a" } },
            .{ .args = &.{ "get", "version", "-o", "json" }, .stdout = "\"1.10\"\n" },
        },
        .content = "version = \"1.10\"\nratio = 1.5\non = true\noff = \"false\"\n",
    },
    .{
        .name = "failed edits leave the file alone",
        .seed = "plain",
        .file = "plain.toml",
        .steps = &.{
            .{
                .args = &.{ "set", "n", "null" },
                .stderr = "snek: this value cannot be written as toml\n",
                .status = 1,
            },
            .{
                .args = &.{ "set", "a.b", "1" },
                .stderr = "snek: \"a.b\" crosses a value that is not a table\n",
                .status = 1,
            },
            .{
                .args = &.{ "set", "a..b", "1" },
                .stderr = "snek: invalid key \"a..b\"\n",
                .status = 1,
            },
            .{
                .args = &.{ "unset", "missing" },
                .stderr = "snek: key \"missing\" is not set in plain.toml\n",
                .status = 1,
            },
        },
        .content = "a = 1\n",
    },
    .{
        .name = "set in a YAML file",
        .seed = "yaml",
        .file = "app.yaml",
        .steps = &.{
            .{ .args = &.{ "set", "server.host", "two words" } },
            .{ .args = &.{ "set", "debug", "false" } },
            .{ .args = &.{ "get", "server.host" }, .stdout = "two words\n" },
        },
        .content = "server:\n  port: 1\n  host: two words\ndebug: false\n",
    },
    .{
        .name = "set in a JSON file",
        .seed = "json",
        .file = "app.json",
        .steps = &.{
            .{ .args = &.{ "set", "server.port", "8080" } },
            .{ .args = &.{ "set", "name", "null" } },
        },
        .content = "{\"name\": null, \"server\": {\"port\": 8080}}\n",
    },
    .{
        .name = "set in an env file",
        .seed = "env",
        .file = "app.env",
        .steps = &.{
            .{ .args = &.{ "set", "server.port", "80" } },
            .{ .args = &.{ "set", "greeting", "hello world" } },
            .{
                .args = &.{ "get", "server", "-o", "json" },
                .stdout = "{\n  \"port\": \"80\"\n}\n",
            },
        },
        .content = "NAME=x\nSERVER__PORT=80\nGREETING=\"hello world\"\n",
    },
    .{
        .name = "fmt rewrites a file",
        .seed = "fmt_json",
        .file = "fmt.json",
        .steps = &.{
            .{ .args = &.{ "fmt", "--check" }, .stdout = "fmt.json\n", .status = 1 },
            .{ .args = &.{"fmt"} },
            .{ .args = &.{ "fmt", "--check" } },
        },
        .content = "{\n  \"b\": [\n    1,\n    2\n  ],\n  \"a\": {\n    \"x\": \"y\"\n  }\n}\n",
    },
    .{
        .name = "fmt keeps TOML comments",
        .seed = "fmt_commented",
        .file = "fmt.toml",
        .steps = &.{.{ .args = &.{"fmt"} }},
        .content = "# A comment that fmt keeps.\na = 1 # and this one\n",
    },
    .{
        .name = "fmt keeps YAML comments",
        .seed = "yaml_commented",
        .file = "fmt.yaml",
        .steps = &.{.{ .args = &.{"fmt"} }},
        .content = "# A comment that set keeps.\nport: 1\n",
    },
    .{
        .name = "fmt keeps comments beside a YAML block scalar",
        .seed = "yaml_block",
        .file = "block.yaml",
        .steps = &.{.{ .args = &.{"fmt"} }},
        .content = "# A comment that fmt keeps, beside a block scalar.\ntext: \"line\\n\"\n",
    },
    .{
        .name = "fmt warns that comments are dropped",
        .seed = "yaml_flow",
        .file = "flow.yaml",
        .steps = &.{.{
            .args = &.{"fmt"},
            .stderr = "snek: warning: flow.yaml: comments are not preserved\n",
        }},
        .content = "list:\n  - a\n  - b\n",
    },
};

/// Each chain's file is printed by `snek cfg get` into the seed step's output directory.
/// Every step re-runs on every build (`has_side_effects`), seed included, so the chain
/// always starts from the seed and never from what an earlier build left behind.
fn addEditChains(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    for (edit_chains) |chain| {
        const seed = b.addRunArtifact(exe);
        seed.setName(b.fmt("e2e: {s}: seed", .{chain.name}));
        seed.setCwd(b.path("test/fixtures"));
        seed.clearEnvironment();
        seed.addArgs(&.{ "cfg", "-c", "seeds.toml", "get", chain.seed });
        seed.has_side_effects = true;
        const file = seed.captureStdOut(.{ .basename = chain.file });
        const dir = file.dirname();

        var previous = &seed.step;
        for (chain.steps, 1..) |edit, index| {
            const run = b.addRunArtifact(exe);
            run.setName(b.fmt("e2e: {s} ({d})", .{ chain.name, index }));
            run.setCwd(dir);
            run.clearEnvironment();
            run.addArg("cfg");
            run.addArgs(edit.args);
            // Positional for `fmt`, a flag for everything else.
            if (std.mem.eql(u8, edit.args[0], "fmt")) {
                run.addArg(chain.file);
            } else {
                run.addArgs(&.{ "-c", chain.file });
            }
            run.has_side_effects = true;
            run.expectStdOutEqual(edit.stdout);
            run.expectStdErrEqual(edit.stderr);
            run.expectExitCode(edit.status);
            run.step.dependOn(previous);
            previous = &run.step;
        }
        const check = b.addCheckFile(file, .{ .expected_exact = chain.content });
        check.setName(b.fmt("e2e: {s}: file contents", .{chain.name}));
        check.step.dependOn(previous);
        step.dependOn(&check.step);
    }
}

/// `encrypt`, then reading the `.enc` file with `-c`, then `decrypt`, on a seeded file.
fn addEncryptChain(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    const seed = b.addRunArtifact(exe);
    seed.setName("e2e: encrypt: seed");
    seed.setCwd(b.path("test/fixtures"));
    seed.clearEnvironment();
    seed.addArgs(&.{ "cfg", "-c", "seeds.toml", "get", "secret" });
    seed.has_side_effects = true;
    const file = seed.captureStdOut(.{ .basename = "secrets.toml" });
    const dir = file.dirname();

    const steps = [_]struct { name: []const u8, args: []const []const u8, stdout: []const u8 }{
        .{ .name = "encrypt", .args = &.{ "cfg", "encrypt", "secrets.toml" }, .stdout = "" },
        .{
            .name = "read",
            .args = &.{ "cfg", "-c", "secrets.toml.enc", "show" },
            .stdout = "db:\n  password: <redacted>\n",
        },
        .{
            .name = "explain",
            .args = &.{ "cfg", "-c", "secrets.toml.enc", "explain", "-o", "json" },
            .stdout =
            \\[
            \\  {
            \\    "key": "db.password",
            \\    "value": "<redacted>",
            \\    "layer": "file",
            \\    "source": "secrets.toml.enc"
            \\  }
            \\]
            \\
            ,
        },
        .{
            .name = "decrypt",
            .args = &.{ "cfg", "decrypt", "secrets.toml.enc" },
            .stdout = "[db]\npassword = \"hunter2\"\n",
        },
    };
    var previous = &seed.step;
    for (steps) |s| {
        const run = b.addRunArtifact(exe);
        run.setName(b.fmt("e2e: encrypt: {s}", .{s.name}));
        run.setCwd(dir);
        run.clearEnvironment();
        run.setEnvironmentVariable("SNEK_PASSPHRASE", "correct horse");
        run.addArgs(s.args);
        run.has_side_effects = true;
        run.expectStdOutEqual(s.stdout);
        run.expectStdErrEqual("");
        run.expectExitCode(0);
        run.step.dependOn(previous);
        previous = &run.step;
    }
    // Without the passphrase, the file cannot be read, and nothing prompts.
    const locked = b.addRunArtifact(exe);
    locked.setName("e2e: encrypt: locked");
    locked.setCwd(dir);
    locked.clearEnvironment();
    locked.addArgs(&.{ "cfg", "-c", "secrets.toml.enc", "show" });
    locked.has_side_effects = true;
    locked.expectStdErrEqual("snek: secrets.toml.enc: encrypted; set SNEK_PASSPHRASE to read it\n");
    locked.expectExitCode(1);
    locked.step.dependOn(previous);
    step.dependOn(&locked.step);
}

/// A run of `snek` (or of `zig build`) in a project chain's directory.
const ProjectStep = struct {
    /// Run `zig` with these arguments and a `--cache-dir` under the build's cache, instead
    /// of `snek`.
    zig: bool = false,
    /// The working directory, relative to the chain's directory.
    cwd: []const u8 = ".",
    args: []const []const u8,
    /// Appends `--module-path=<this checkout>`.
    module_path: bool = false,
    /// Null leaves the stream unchecked.
    stdout: ?[]const u8 = "",
    stderr: ?[]const u8 = "",
    status: u8 = 0,
};

/// Steps run in order in a fresh directory, then `files` checked: path, then a substring.
const ProjectChain = struct {
    name: []const u8,
    steps: []const ProjectStep,
    files: []const [2][]const u8 = &.{},
};

const demo_created =
    \\created demo/build.zig
    \\created demo/build.zig.zon
    \\created demo/src/main.zig
    \\created demo/src/cmd/hello.zig
    \\created demo/src/settings.zig
    \\created demo/README.md
    \\created demo/.gitignore
    \\
++ "next: cd demo" ++ then ++ "zig build run -- --help\n";

/// How `snek cli init` joins the commands of its "next:" hint.
const then = if (builtin.os.tag == .windows) "\n      " else " && ";

const project_chains = [_]ProjectChain{
    .{
        .name = "init, add twice, build, and run",
        .steps = &.{
            .{ .args = &.{ "cli", "init", "demo" }, .module_path = true, .stdout = demo_created },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "greet", "-f", "name:string,short=n" },
                .stdout = "created demo/src/cmd/greet.zig\nupdated demo/src/main.zig\n",
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "config", "get", "--args", "1" },
                .stdout = "created demo/src/cmd/config/main.zig\n" ++
                    "created demo/src/cmd/config/get.zig\nupdated demo/src/main.zig\n",
            },
            .{
                .args = &.{ "cli", "init", "demo" },
                .stderr = "snek: demo: directory is not empty (use --force to write into it)\n",
                .status = 1,
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "hello" },
                .stderr = "snek: src/cmd/hello.zig: the command already exists\n",
                .status = 1,
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "hello", "world" },
                .stderr = "snek: src/cmd/hello.zig: \"hello\" is a command, not a group\n",
                .status = 1,
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "x", "--flag", "bad" },
                .stderr = "snek: flag spec \"bad\" needs name:type\n" ++
                    "Run 'snek cli add --help' for usage.\n",
                .status = 2,
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "../x" },
                .stderr = "snek: invalid command name \"../x\" (use lowercase words joined by " ++
                    "-, not main)\nRun 'snek cli add --help' for usage.\n",
                .status = 2,
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "main" },
                .stderr = "snek: invalid command name \"main\" (use lowercase words joined by " ++
                    "-, not main)\nRun 'snek cli add --help' for usage.\n",
                .status = 2,
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "x", "--args", "3:1" },
                .stderr = "snek: invalid --args \"3:1\" (use N, N:M, or N:)\n" ++
                    "Run 'snek cli add --help' for usage.\n",
                .status = 2,
            },
            .{
                .args = &.{
                    "cli",                     "add",                          "-C",
                    "demo",                    "deploy",                       "--flow",
                    "--flag",                  "env:enum(staging|production)", "--flag",
                    "version:string,required",
                },
                .stdout = "created demo/src/cmd/deploy.zig\nupdated demo/src/main.zig\n",
            },
            .{
                .args = &.{ "cli", "add", "-C", "demo", "x", "--flow", "--args", "1" },
                .stderr = "snek: a --flow takes no --args\nRun 'snek cli add --help' for usage.\n",
                .status = 2,
            },
            .{ .zig = true, .cwd = "demo", .args = &.{ "build", "test" }, .stderr = null },
            .{
                .zig = true,
                .cwd = "demo",
                .args = &.{
                    "build", "run",        "--",        "deploy", "-q",
                    "--env", "production", "--version", "1",
                },
                .stdout = "deploy\nenv=production\nversion=1\n",
                .stderr = null,
            },
            .{
                .zig = true,
                .cwd = "demo",
                .args = &.{ "build", "run", "--", "greet", "-n", "zig" },
                .stdout = "greet\nname=zig\n",
                .stderr = null,
            },
            .{
                .zig = true,
                .cwd = "demo",
                .args = &.{ "build", "run", "--", "hello" },
                .stdout = "hello\nname=world\n",
                .stderr = null,
            },
            .{ .zig = true, .cwd = "demo", .args = &.{ "build", "schema" }, .stderr = null },
            .{
                .cwd = "demo",
                .args = &.{ "cfg", "init", "demo.toml", "--schema", "zig-out/schema.json" },
            },
        },
        .files = &.{
            .{ "demo/src/main.zig", "@import(\"cmd/config/main.zig\").command," },
            .{ "demo/src/cmd/config/main.zig", "@import(\"get.zig\").command," },
            .{
                "demo/demo.toml",
                "log_level = \"info\"\n\n[server]\nhost = \"localhost\"\nport = 8080\n",
            },
        },
    },
    .{
        .name = "init without a dependency",
        .steps = &.{.{
            .args = &.{ "cli", "init", "z" },
            .stdout =
            \\created z/build.zig
            \\created z/build.zig.zon
            \\created z/src/main.zig
            \\created z/src/cmd/hello.zig
            \\created z/src/settings.zig
            \\created z/README.md
            \\created z/.gitignore
            \\
            ++ "next: cd z" ++ then ++ "zig fetch --save=snek <url of snek>\n",
        }},
        .files = &.{.{ "z/build.zig.zon", ".dependencies = .{}," }},
    },
};

/// POSIX paths again.
const posix_project_chains = [_]ProjectChain{.{
    .name = "init with a module path that is not snek creates nothing",
    .steps = &.{
        .{
            .args = &.{ "cli", "init", "x", "--module-path", "/tmp" },
            .stderr = "snek: /tmp: not a snek checkout (no src/cli/root.zig)\n",
            .status = 1,
        },
        .{
            .args = &.{ "cli", "add", "-C", "x", "hello" },
            .stderr = "snek: x: cannot open: FileNotFound\n",
            .status = 1,
        },
    },
}};

fn addProjectChains(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    for (project_chains) |chain| addProjectChain(b, exe, step, chain);
    if (builtin.os.tag != .windows) {
        for (posix_project_chains) |chain| addProjectChain(b, exe, step, chain);
    }
}

/// The chain's directory is the output directory of a `snek version` run. No step has side
/// effects, so, as in `addEditCase`, the whole chain is cached and runs again, in a new
/// directory, only when the binary changes (the build system never empties a directory it
/// reuses). The generated project is built with a cache under the build's own, so it is
/// reused between builds and stays off the source tree's file system.
fn addProjectChain(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step: *std.Build.Step,
    chain: ProjectChain,
) void {
    const seed = b.addRunArtifact(exe);
    seed.setName(b.fmt("e2e: {s}: directory", .{chain.name}));
    seed.clearEnvironment();
    seed.addArg("version");
    // The basename keeps each chain's directory apart.
    const dir = seed.captureStdOut(.{ .basename = b.fmt("{s}.txt", .{chain.name}) }).dirname();

    var previous = &seed.step;
    for (chain.steps, 1..) |project_step, index| {
        const run = projectRun(b, exe, project_step);
        run.setName(b.fmt("e2e: {s} ({d})", .{ chain.name, index }));
        run.setCwd(dir.path(b, project_step.cwd));
        if (project_step.stdout) |bytes| run.expectStdOutEqual(bytes);
        if (project_step.stderr) |bytes| run.expectStdErrEqual(bytes);
        run.expectExitCode(project_step.status);
        run.step.dependOn(previous);
        previous = &run.step;
    }
    for (chain.files) |file| {
        const check = b.addCheckFile(dir.path(b, file[0]), .{ .expected_matches = &.{file[1]} });
        check.setName(b.fmt("e2e: {s}: {s}", .{ chain.name, file[0] }));
        check.step.dependOn(previous);
        previous = &check.step;
    }
    step.dependOn(previous);
}

fn projectRun(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    project_step: ProjectStep,
) *std.Build.Step.Run {
    if (!project_step.zig) {
        const run = b.addRunArtifact(exe);
        run.clearEnvironment();
        run.addArgs(project_step.args);
        if (project_step.module_path) run.addPrefixedDirectoryArg("--module-path=", b.path("."));
        return run;
    }
    // `zig build` keeps the environment: it finds its global cache through it.
    const run = std.Build.Step.Run.create(b, "zig");
    run.addArg(b.graph.zig_exe);
    run.addArg(project_step.args[0]);
    run.addArg("--cache-dir");
    run.addDirectoryArg(.{ .relative = .{
        .base = .local_cache,
        .sub_path = "e2e-project",
    } });
    run.addArgs(project_step.args[1..]);
    return run;
}

/// Completion as the shells run it: `test/complete.<shell>` loads the script that
/// `snek cli completion <shell>` prints, completes the last word, and prints the result.
const ShellCase = struct {
    words: []const []const u8,
    stdout: []const u8,
};

const bash_cases = [_]ShellCase{
    .{
        .words = &.{ "cfg", "" },
        .stdout = "get\nkeys\nshow\nexplain\nenv\nprofile\nset\nunset\nedit\n" ++
            "convert\nvalidate\nfmt\nredact\ndiff\n" ++
            "encrypt\ndecrypt\nmerge\ninit\nschema\n",
    },
    .{ .words = &.{ "cfg", "get", "-o", "y" }, .stdout = "yaml\n" },
    .{ .words = &.{ "cfg", "get", "--pro" }, .stdout = "--profile\n" },
    .{ .words = &.{ "cfg", "get", "server.p" }, .stdout = "server.port\n" },
    // Directives: files of the formats snek reads, directories.
    .{ .words = &.{ "cfg", "-c", "se" }, .stdout = "seeds.toml\nservers.toml\n" },
    .{ .words = &.{ "cli", "docs", "--dir", "y" }, .stdout = "yaml\n" },
    // After `--flag=`, as one word and as bash splits it at the `=`.
    .{
        .words = &.{ "cfg", "--config=se" },
        .stdout = "--config=seeds.toml\n--config=servers.toml\n",
    },
    .{ .words = &.{ "cfg", "--config", "=", "se" }, .stdout = "seeds.toml\nservers.toml\n" },
    .{ .words = &.{ "cli", "docs", "--dir=y" }, .stdout = "--dir=yaml/\n" },
    .{
        .words = &.{ "cli", "completion", "" },
        .stdout = "bash\nzsh\nfish\npowershell\ninstall\n",
    },
};

const zsh_cases = [_]ShellCase{
    .{
        .words = &.{ "cfg", "ex" },
        .stdout = "explain:Show where each value comes from\n",
    },
    .{ .words = &.{ "cfg", "show", "--layer", "f" }, .stdout = "file:\nflag:\n" },
    .{ .words = &.{ "cfg", "get", "--o" }, .stdout = "--output:Output format\n" },
    // Nothing to offer: the script falls back to file names.
    .{ .words = &.{ "cfg", "get", "k" }, .stdout = "<files>\n" },
    .{
        .words = &.{ "cfg", "validate", "s" },
        .stdout = "<files -g *.(toml|yaml|yml|json|zon|env|jsonc|ini)>\n",
    },
    .{ .words = &.{ "cli", "docs", "--dir", "" }, .stdout = "<files -/>\n" },
    .{ .words = &.{ "cli", "docs", "--dir=y" }, .stdout = "<files -/ after --dir=>\n" },
};

const fish_cases = [_]ShellCase{
    .{
        .words = &.{ "cfg", "ex" },
        .stdout = "explain\tShow where each value comes from\n",
    },
    .{ .words = &.{ "cfg", "show", "--layer", "f" }, .stdout = "file\nflag\n" },
    .{ .words = &.{ "cfg", "get", "--o" }, .stdout = "--output\tOutput format\n" },
    .{ .words = &.{ "cfg", "explain", "server.h" }, .stdout = "server.host\n" },
    .{ .words = &.{ "cfg", "-c", "se" }, .stdout = "seeds.toml\nservers.toml\n" },
    .{ .words = &.{ "cli", "docs", "--dir", "y" }, .stdout = "yaml/\n" },
    .{
        .words = &.{ "cfg", "--config=se" },
        .stdout = "--config=seeds.toml\n--config=servers.toml\n",
    },
};

const powershell_cases = [_]ShellCase{
    // One word before the current one: the case the script once split into characters.
    .{
        .words = &.{ "cfg", "ex" },
        .stdout = "explain\tShow where each value comes from\n",
    },
    .{ .words = &.{ "cfg", "get", "-o", "y" }, .stdout = "yaml\tyaml\n" },
    .{
        .words = &.{ "cfg", "-c", "se" },
        .stdout = "seeds.toml\tseeds.toml\nservers.toml\tservers.toml\n",
    },
    .{ .words = &.{ "cfg", "get", "--o" }, .stdout = "--output\tOutput format\n" },
    .{
        .words = &.{ "cfg", "--config=se" },
        .stdout = "--config=seeds.toml\t--config=seeds.toml\n" ++
            "--config=servers.toml\t--config=servers.toml\n",
    },
    .{
        .words = &.{ "cli", "completion", "" },
        .stdout = "bash\tPrint the bash completion script\n" ++
            "zsh\tPrint the zsh completion script\n" ++
            "fish\tPrint the fish completion script\n" ++
            "powershell\tPrint the powershell completion script\n" ++
            "install\tInstall the completion script for your shell\n",
    },
};

/// A shell that runs one of the `test/complete.*` scripts.
const Shell = struct {
    /// A plain argument, not a file input: the build would hash a file input, and
    /// `WindowsApps\pwsh.EXE` (PowerShell from the Store) is an alias that cannot be opened.
    program: []const u8,
    args: []const []const u8 = &.{},
    script: []const u8,
    /// PowerShell needs its environment (on Windows, `SystemRoot` and the like).
    clear_environment: bool = true,
};

/// Each shell is optional except bash on POSIX hosts; look for them while configuring.
fn addShellCompletion(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
    if (builtin.os.tag != .windows) {
        const bash = findShell(b, "bash") orelse "bash";
        const shell: Shell = .{ .program = bash, .script = "test/complete.bash" };
        addShellCases(b, exe, step, shell, &bash_cases);
    }
    if (findShell(b, "zsh")) |zsh| {
        const shell: Shell = .{ .program = zsh, .args = &.{"-f"}, .script = "test/complete.zsh" };
        addShellCases(b, exe, step, shell, &zsh_cases);
    }
    if (findShell(b, "fish")) |fish| {
        const shell: Shell = .{
            .program = fish,
            .args = &.{"--no-config"},
            .script = "test/complete.fish",
        };
        addShellCases(b, exe, step, shell, &fish_cases);
    }
    if (findShell(b, "pwsh")) |pwsh| {
        const shell: Shell = .{
            .program = pwsh,
            .args = &.{ "-NoLogo", "-NoProfile", "-NonInteractive", "-File" },
            .script = "test/complete.ps1",
            .clear_environment = false,
        };
        addShellCases(b, exe, step, shell, &powershell_cases);
    }
}

fn findShell(b: *std.Build, name: []const u8) ?[]const u8 {
    return b.findProgram(.{ .names = &.{name} });
}

fn addShellCases(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step: *std.Build.Step,
    shell: Shell,
    shell_cases: []const ShellCase,
) void {
    for (shell_cases) |case| {
        const run = std.Build.Step.Run.create(b, b.fmt("e2e: {s} snek {s}", .{
            std.fs.path.extension(shell.script)[1..],
            std.mem.join(b.allocator, " ", case.words) catch @panic("OOM"),
        }));
        run.addArg(shell.program);
        run.addArgs(shell.args);
        run.addFileArg(b.path(shell.script));
        run.addArtifactArg(exe);
        run.addArgs(case.words);
        run.setCwd(b.path("test/fixtures"));
        if (shell.clear_environment) run.clearEnvironment();
        run.expectStdOutEqual(case.stdout);
        run.expectStdErrEqual("");
        run.expectExitCode(0);
        step.dependOn(&run.step);
    }
}
