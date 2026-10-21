//! `cli` - command-line applications from typed declarations.
//!
//! ```zig
//! const cli = @import("cli");
//!
//! const ServeFlags = struct {
//!     port: u16 = 8080,
//!     verbose: u8 = 0,
//! };
//!
//! // What the fields mean (shared with `cfg`), then how they are spelled here.
//! const Specs = field.Set(.{field.Spec(ServeFlags){ .fields = .{
//!     .port = .{ .help = "Port to listen on", .checks = &.{.min(1)} },
//! } }});
//! const serve_flags = cli.flags(ServeFlags, Specs, .{ .fields = .{
//!     .port = .{ .short = 'p', .env = "PORT" },
//!     .verbose = .{ .short = 'v', .count = true },
//! } });
//!
//! fn serve(ctx: *cli.Context, flags: ServeFlags) !void {
//!     try ctx.out.print("listening on {d}\n", .{flags.port});
//! }
//!
//! const root = cli.command(.{
//!     .name = "app",
//!     .summary = "An example",
//!     .subcommands = .{
//!         cli.command(.{ .name = "serve", .flags = serve_flags, .run = serve }),
//!     },
//! });
//!
//! pub fn main(init: std.process.Init) u8 {
//!     const app: cli.App = .{ .root = &root, .version = "0.1.0" };
//!     return app.run(init);
//! }
//! ```
//!
//! The module imports `std`, `term` (for display widths, color detection, and the styles
//! of `Theme`), and `field` (specs, shared with `cfg`). Flag types may follow the `parse`
//! convention shared with `cfg` (`pub fn parse(text: []const u8) !T`), and
//! `Context.changedFlags` returns records that `cfg.Config.bindFlags` accepts.

const std = @import("std");

/// An application: a command tree and how to run it. `app.run(init)` in `main`.
pub const App = @import("App.zig");
/// One command of the tree, usually built by `command`.
pub const Command = @import("Command.zig");
/// What a handler receives: I/O, allocators, output, and the parsed command line.
pub const Context = @import("Context.zig");
/// One flag's descriptor, usually derived from a field of a flags struct.
pub const Flag = @import("Flag.zig");
/// Every sentence the library shows, replaceable to translate them: `App.messages`.
pub const Messages = @import("Messages.zig");
/// How help and the runner's messages look: `App.theme`.
pub const Theme = @import("Theme.zig");
/// What a completer (`.complete` of a flag or positional, or of `.args`) returns.
pub const Candidate = Command.Candidate;

/// Builds a `Command` from a declarative spec at compile time. See `spec.zig`.
pub const command = spec.command;
/// The flags a struct's fields become: what they mean from `field` specs, how they are
/// spelled from per-place options. A command's `.flags`. See `sets.zig`.
pub const flags = sets.flags;
/// The positionals a struct's fields become, in order. A command's `.args`.
pub const args = sets.args;
/// The options `flags` takes: per field, its spelling; flag groups.
pub const FlagOptions = sets.FlagOptions;
/// The options of a field that is a group of flags (its prefix, separator, variables), the
/// same type in any flags struct, so one can be shared: `.cursor = shared_group`.
pub const GroupPlace = sets.GroupPlace;
/// The options `args` takes: per field, its name, completion, and prompt.
pub const ArgOptions = sets.ArgOptions;
/// A completer for a flag's or positional's `.complete`: `.from(fn)`.
pub const Complete = sets.Complete;
/// The flags of a plain flags struct, for building a `Command` by hand.
pub const flagsOf = spec.flagsOf;

/// Where flag defaults come from besides the command line and the environment, such as a
/// configuration file: the type of `App.defaults`.
pub const Defaults = parse.Defaults;
/// Flag defaults from a configuration: `App.defaults = .from(&config, .{})`.
pub const defaults = @import("defaults.zig");
/// Help pages: what `--help` writes, and searching them (`help --search`).
pub const help = @import("help.zig");
/// Shell completion: the scripts, the `completion` command, and the `__complete2` protocol.
pub const complete = @import("complete.zig");
/// Documentation of a command tree: Markdown, man pages, HTML, JSON.
pub const docs = @import("docs.zig");
/// A command tree as JSON, for tools that read it.
pub const json = @import("json.zig");
/// What the terminal is: its width, its colors, whether the run is interactive.
pub const terminal = @import("terminal.zig");
/// Ctrl-C as a request to stop: `App.cancel_on_interrupt`.
pub const interrupt = @import("interrupt.zig");
/// Asking for missing flags: `App.prompter`.
pub const prompt = @import("prompt.zig");
/// Running a command tree as an interactive shell.
pub const repl = @import("repl.zig");
/// Commands from other programs on `PATH`, as git runs `git-<name>`: `App.plugins`.
pub const plugins = @import("plugins.zig");
/// Showing long text through `$PAGER`: `App.pager`.
pub const pager = @import("pager.zig");
/// Translations of the library's sentences and the app's own: `App.translations`.
pub const i18n = @import("i18n.zig");
/// Commands that are graphs of questions and actions: setup wizards, installers, deploys.
pub const flow = @import("flow.zig");
/// A flow over a state type and an enum of steps. See `flow.zig`.
pub const Flow = flow.Flow;
/// `--version` text with the commit and date of the build.
pub const version = @import("version.zig");
/// Running an app in a test: `testing.run(app, args, .{ .env = ... })`.
pub const testing = @import("testing.zig");

/// The library's own parts, public for its files and for the curious, but not stable:
/// they change in any release (see docs/stability.md).
pub const internal = struct {
    pub const spec = @import("spec.zig");
    pub const sets = @import("sets.zig");
    pub const parse = @import("parse.zig");
    pub const values = @import("values.zig");
    pub const text = @import("text.zig");
    pub const shell = @import("shell.zig");
    pub const output = @import("output.zig");
};

const spec = internal.spec;
const sets = internal.sets;
const parse = internal.parse;

test {
    // `refAllDecls` is shallow, so every file is named here; a file missing from this list
    // would have its tests silently skipped.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(internal);
    std.testing.refAllDecls(App);
    std.testing.refAllDecls(Command);
    std.testing.refAllDecls(Context);
    std.testing.refAllDecls(Flag);
    std.testing.refAllDecls(Messages);
    std.testing.refAllDecls(Theme);
    std.testing.refAllDecls(internal.spec);
    std.testing.refAllDecls(internal.parse);
    std.testing.refAllDecls(defaults);
    std.testing.refAllDecls(help);
    std.testing.refAllDecls(complete);
    std.testing.refAllDecls(docs);
    std.testing.refAllDecls(json);
    std.testing.refAllDecls(internal.shell);
    std.testing.refAllDecls(internal.values);
    std.testing.refAllDecls(internal.text);
    std.testing.refAllDecls(terminal);
    std.testing.refAllDecls(interrupt);
    std.testing.refAllDecls(prompt);
    std.testing.refAllDecls(repl);
    std.testing.refAllDecls(plugins);
    std.testing.refAllDecls(pager);
    std.testing.refAllDecls(i18n);
    std.testing.refAllDecls(internal.output);
    std.testing.refAllDecls(flow);
    std.testing.refAllDecls(i18n.messages);
    std.testing.refAllDecls(version);
    std.testing.refAllDecls(testing);
}
