# `field`

What settings mean, shared by [`cli`](cli.md) and [`cfg`](cfg.md): each field's help, whether it
is secret or deprecated, and the checks its value must pass. How a field is spelled is not
here: flag names, short flags, keys, and environment variables are `cli.flags`' and
`cfg.settings`' options, per place.

- [Specs](#specs)
- [Checks](#checks)
- [Sets, by type](#sets-by-type)

## Specs

```zig
const field = @import("field");

const Listener = struct { host: []const u8 = "0.0.0.0", port: u16 = 8080 };

fn notReserved(port: u16, w: *std.Io.Writer) !void {
    if (port == 6000) return field.fail(w, "is reserved for X11", .{});
}

const listener: field.Spec(Listener) = .{ .fields = .{
    .host = .{ .help = "Address to bind" },
    .port = .{ .help = "Port to listen on", .checks = &.{ .min(1), .from(notReserved) } },
} };
```

| per field | |
|---|---|
| `.help` | help text: `cli`'s help and docs, `cfg`'s schema |
| `.secret` | never shown: not echoed, redacted in help, docs, messages, and written files |
| `.deprecated = "why"` | still read, with this notice when set |
| `.checks` | checks on the value (when set, for an optional) |
| `.each` | checks on each element of a list |

A spec's own `.checks` are checks across the struct's fields, run once every field has a
value. A tagged union's spec has one entry per variant.

## Checks

A check is a plain function, `fn (V, *std.Io.Writer) !void`, that writes why a value is wrong
and returns `error.Invalid`; `field.fail(w, fmt, args)` does both. It imports nothing from
`cli` or `cfg`. `.from(f)` makes it a check; the built-in ones are written the same way, as
decl literals:

| check | on |
|---|---|
| `.min(n)`, `.max(n)` | numbers, and any type with `order(a, b) std.math.Order` (`.min(.millis(10))`) |
| `.minLen(n)`, `.maxLen(n)` | strings (in characters) and lists |
| `.oneOf(&.{ "a", "b" })` | strings; an enum gives its choices by itself |
| `.glob("*.pem")` | strings: `*` any run of bytes, `?` one byte |

The built-in checks describe themselves (`About`), so help shows `(1 to 64)`, docs and
schemas carry the bounds, and completion offers `.oneOf`'s values. Every failure is reported,
not just the first. A check given to a field of another type, or a bound that does not fit
it, is a compile error at the spec.

## Sets, by type

A `field.Set` gathers specs, at most one per type, and applies each wherever its type occurs:
nested in a group, in an optional, in a list, or in a choice's variant. A `Listener` spec
covers `public: Listener`, `admin: ?Listener`, and every element of `mirrors: []const
Listener` alike, so a module can ship its types with their rules:

```zig
pub const specs = .{ listener, tls };                 // net.zig
const Specs = field.Set(.{ app } ++ net.specs);       // main.zig
```

`cli.flags(T, Specs, options)`, `cli.args(T, Specs, options)`, and `cfg.settings(T, Specs, keys)`
take a set; `field.none` is the empty one.
