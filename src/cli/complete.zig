//! Shell completion.
//!
//! The scripts are thin: each calls back into the program as
//! `<app> __complete2 <words before the cursor...> <word at the cursor>` and offers what it
//! prints, one `candidate<TAB>description` per line. All knowledge stays in the binary, so
//! completion can never drift from the command tree. When nothing is printed, the scripts
//! fall back to the shell's file completion.
//!
//! After the candidates, `__complete2` may print directives, which the scripts carry out
//! with the shell's own file completion: `:file <ext>` (files ending in `.<ext>`, one line
//! per extension), `:files` (any file), and `:dirs` (directories). For a `--flag=value`
//! word, `:prefix --flag=` comes first: the scripts complete the paths after it and keep it
//! on each. `__complete`, which the scripts of earlier versions call, prints the
//! candidates alone.

const std = @import("std");
const sets = @import("sets.zig");
const field = @import("field");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Command = @import("Command.zig");
const Flag = @import("Flag.zig");
const parse = @import("parse.zig");
const help = @import("help.zig");
const spec = @import("spec.zig");
const Context = @import("Context.zig");
const Messages = @import("Messages.zig");
const i18n = @import("i18n.zig");

/// A shell completion scripts are written for.
pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,

    /// The shell named `name` (`bash`), or null.
    pub fn fromName(name: []const u8) ?Shell {
        for (std.enums.values(Shell)) |shell| {
            if (std.mem.eql(u8, name, @tagName(shell))) return shell;
        }
        return null;
    }
};

/// What completion offers beyond the command tree.
pub const Options = struct {
    /// `help [command...]` on the root.
    help_command: bool = true,
    /// `-q`/`--quiet` everywhere.
    quiet: bool = false,
    /// What completers (`.complete`) run with. Without it, they are not called.
    runtime: ?Runtime = null,
    /// Descriptions of the built-ins.
    messages: *const Messages = &Messages.english,
    /// Translates summaries and flag help.
    translation: ?*const i18n.Translation = null,
    /// Print the directives completers ask for (`__complete2`).
    directives: bool = false,
    /// Descend into a subcommand named by an unambiguous prefix, as `App.prefix_matching`
    /// runs it.
    prefix_matching: bool = false,
};

/// The application's side of a completer's `Context`.
pub const Runtime = struct {
    io: std.Io,
    gpa: Allocator,
    /// Holds the parse and whatever completers allocate.
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    app_name: []const u8,
    user_data: ?*anyopaque = null,
    /// How the words before the cursor are parsed; `partial` is set regardless.
    parse: parse.Options = .{},
};

/// Writes the completion candidates for `words`; the last word is the one being completed
/// and may be empty.
pub fn candidates(
    writer: *Writer,
    root: *const Command,
    words: []const []const u8,
    options: Options,
) Writer.Error!void {
    var path_buffer: [parse.max_depth]*const Command = undefined;
    path_buffer[0] = root;
    var depth: usize = 1;
    var positionals: usize = 0;
    var pending: ?*const Flag = null;
    var flags_ended = false;

    const before = if (words.len > 0) words[0 .. words.len - 1] else words;
    const current = if (words.len > 0) words[words.len - 1] else "";
    for (before) |word| {
        const path = path_buffer[0..depth];
        if (pending != null) {
            pending = null;
        } else if (flags_ended) {
            positionals += 1;
        } else if (std.mem.eql(u8, word, "--")) {
            flags_ended = true;
        } else if (std.mem.startsWith(u8, word, "--")) {
            if (std.mem.indexOfScalar(u8, word, '=') == null) {
                pending = valueFlag(findLong(path, word[2..]));
            }
        } else if (word.len > 1 and word[0] == '-') {
            pending = pendingShort(path, word[1..]);
        } else if (positionals == 0 and depth < path_buffer.len and
            subcommandFor(path[depth - 1], word, options.prefix_matching) != null)
        {
            path_buffer[depth] = subcommandFor(path[depth - 1], word, options.prefix_matching).?;
            depth += 1;
        } else {
            positionals += 1;
        }
    }

    const path = path_buffer[0..depth];
    const leaf = path[depth - 1];
    if (pending) |flag| {
        try writeChoices(writer, flag, "", current);
        // The flag is the last word before the cursor; parse what precedes it.
        const parsed = before[0 .. before.len - 1];
        return writeCustom(writer, root, parsed, flag.complete, "", current, options);
    }
    if (!flags_ended and std.mem.startsWith(u8, current, "--")) {
        if (std.mem.indexOfScalar(u8, current, '=')) |eq| {
            const flag = findLong(path, current[2..eq]) orelse return;
            const prefix = current[0 .. eq + 1];
            try writeChoices(writer, flag, prefix, current[eq + 1 ..]);
            const value = current[eq + 1 ..];
            return writeCustom(writer, root, before, flag.complete, prefix, value, options);
        }
        return writeFlags(writer, path, current, options);
    }
    if (!flags_ended and std.mem.startsWith(u8, current, "-")) {
        return writeFlags(writer, path, current, options);
    }
    const args_complete = if (leaf.run != null) leaf.args.complete else null;
    // After `--` every word is a positional, as it is to the parser.
    if (positionals > 0 or flags_ended) {
        return writeCustom(writer, root, before, args_complete, "", current, options);
    }
    for (leaf.subcommands) |sub| {
        if (!advertised(sub) or !std.mem.startsWith(u8, sub.name, current)) continue;
        try writer.print(
            "{s}\t{s}\n",
            .{ sub.name, i18n.textIn(options.translation, sub.summary) },
        );
    }
    if (options.help_command and depth == 1) {
        const name = help.help_command[0];
        if (leaf.findSubcommand(name) == null and std.mem.startsWith(u8, name, current)) {
            try writer.print("{s}\t{s}\n", .{ name, options.messages.help_command });
        }
    }
    try writeCustom(writer, root, before, args_complete, "", current, options);
}

/// Runs `completer`, if any, and writes what it offers that starts with `current`, each
/// after `prefix` (`--flag=`). A completer that fails offers nothing: completion must
/// never print an error into the shell's prompt.
fn writeCustom(
    writer: *Writer,
    root: *const Command,
    before: []const []const u8,
    completer: ?Command.Completer,
    prefix: []const u8,
    current: []const u8,
    options: Options,
) Writer.Error!void {
    const function = completer orelse return;
    const runtime = options.runtime orelse return;
    const offered = runCompleter(runtime, root, before, function, current) catch return;
    for (offered) |candidate| {
        if (candidate.kind != .value) continue;
        if (!std.mem.startsWith(u8, candidate.value, current)) continue;
        try writer.print("{s}{s}", .{ prefix, candidate.value });
        if (candidate.description.len > 0) try writer.print("\t{s}", .{candidate.description});
        try writer.writeByte('\n');
    }
    if (!options.directives) return;
    for (offered) |candidate| {
        if (candidate.kind == .value) continue;
        if (prefix.len > 0) try writer.print(":prefix {s}\n", .{prefix});
        break;
    }
    var directories = false;
    for (offered) |candidate| switch (candidate.kind) {
        .value => {},
        .files => if (candidate.value.len == 0) {
            try writer.writeAll(":files\n");
        } else {
            try writer.print(":file {s}\n", .{candidate.value});
            directories = true; // To reach the files in them.
        },
        .directories => directories = true,
    };
    if (directories) try writer.writeAll(":dirs\n");
}

fn runCompleter(
    runtime: Runtime,
    root: *const Command,
    before: []const []const u8,
    function: Command.Completer,
    current: []const u8,
) anyerror![]const Command.Candidate {
    var parse_options = runtime.parse;
    parse_options.partial = true;
    var usage: parse.Usage = .{};
    const result = try parse.parse(runtime.arena, root, before, parse_options, &usage);
    // Whatever the completer prints would corrupt the protocol.
    var discard: Writer.Discarding = .init(&.{});
    var ctx: Context = .{
        .io = runtime.io,
        .gpa = runtime.gpa,
        .arena = runtime.arena,
        .environ = runtime.environ,
        .out = &discard.writer,
        .err = &discard.writer,
        .args = result.positionals,
        .path = result.path,
        .occurrences = result.occurrences,
        .app_name = runtime.app_name,
        .user_data = runtime.user_data,
        .quiet = true,
    };
    return function(&ctx, current);
}

/// The subcommand `word` names, by name or alias, or (with `prefix`) by an unambiguous
/// prefix.
fn subcommandFor(cmd: *const Command, word: []const u8, prefix: bool) ?*const Command {
    if (cmd.findSubcommand(word)) |sub| return sub;
    if (!prefix or word.len == 0) return null;
    var found: ?*const Command = null;
    for (cmd.subcommands) |*sub| {
        if (!advertised(sub.*) or !std.mem.startsWith(u8, sub.name, word)) continue;
        if (found != null) return null;
        found = sub;
    }
    return found;
}

/// Whether completion offers `sub`: hidden and deprecated commands run when typed, but are
/// not offered.
fn advertised(sub: Command) bool {
    return !sub.hidden and sub.deprecated == null;
}

fn valueFlag(flag: ?*const Flag) ?*const Flag {
    const f = flag orelse return null;
    return if (f.takesValue()) f else null;
}

/// The flag in a bundle of shorts (`-vo`) still waiting for its value in the next word: the
/// first one that takes a value, when it ends the bundle. `-vojson` holds its value.
fn pendingShort(path: []const *const Command, bundle: []const u8) ?*const Flag {
    for (bundle, 0..) |c, i| {
        const flag = findShort(path, c) orelse return null;
        if (flag.takesValue()) return if (i == bundle.len - 1) flag else null;
    }
    return null;
}

fn findLong(path: []const *const Command, name: []const u8) ?*const Flag {
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (flag.matches(name)) return flag;
    }
    return null;
}

fn findShort(path: []const *const Command, c: u8) ?*const Flag {
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (flag.short == c) return flag;
    }
    return null;
}

fn writeChoices(
    writer: *Writer,
    flag: *const Flag,
    prefix: []const u8,
    current: []const u8,
) Writer.Error!void {
    for (flag.choices) |choice| {
        if (std.mem.startsWith(u8, choice, current)) {
            try writer.print("{s}{s}\n", .{ prefix, choice });
        }
    }
}

fn writeFlags(
    writer: *Writer,
    path: []const *const Command,
    current: []const u8,
    options: Options,
) Writer.Error!void {
    var it = parse.visible(path);
    while (it.next()) |flag| {
        if (flag.hidden or flag.deprecated != null) continue;
        if (findLong(path, flag.name) != flag) continue; // Shadowed by a nearer flag.
        var buffer: [80]u8 = undefined;
        const spelled = std.fmt.bufPrint(&buffer, "--{s}", .{flag.name}) catch continue;
        if (std.mem.startsWith(u8, spelled, current)) {
            try writer.print(
                "{s}\t{s}\n",
                .{ spelled, i18n.textIn(options.translation, flag.help) },
            );
        }
    }
    if (std.mem.startsWith(u8, "--help", current)) {
        try writer.print("--help\t{s}\n", .{options.messages.show_help});
    }
    const quiet_is_builtin = options.quiet and findLong(path, "quiet") == null;
    if (quiet_is_builtin and std.mem.startsWith(u8, "--quiet", current)) {
        try writer.print("--quiet\t{s}\n", .{options.messages.quiet_flag});
    }
}

/// Writes the completion script for `shell`, for a program called `name`.
/// `generator` is the command line that prints this script, such as `app completion bash`;
/// the script's header tells the user how to load it.
pub fn script(
    writer: *Writer,
    shell: Shell,
    name: []const u8,
    generator: []const u8,
) Writer.Error!void {
    var ident_buffer: [64]u8 = undefined;
    const ident = identifier(&ident_buffer, name);
    const template = switch (shell) {
        .bash => bash_script,
        .zsh => zsh_script,
        .fish => fish_script,
        .powershell => powershell_script,
    };
    // `@NAME@`, `@IDENT@`, and `@GENERATOR@` stand for the program, a shell identifier
    // made from it, and the command that prints the script.
    var rest: []const u8 = template;
    while (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        try writer.writeAll(rest[0..at]);
        rest = rest[at..];
        const markers = [_]struct { []const u8, []const u8 }{
            .{ "@NAME@", name },
            .{ "@IDENT@", ident },
            .{ "@GENERATOR@", generator },
        };
        for (markers) |marker| {
            if (std.mem.startsWith(u8, rest, marker[0])) {
                try writer.writeAll(marker[1]);
                rest = rest[marker[0].len..];
                break;
            }
        } else {
            try writer.writeByte('@');
            rest = rest[1..];
        }
    }
    try writer.writeAll(rest);
}

const bash_script =
    \\# bash completion for @NAME@. Load with:
    \\#   source <(@GENERATOR@)
    \\_@IDENT@_complete() {
    \\    local cur="${COMP_WORDS[COMP_CWORD]}"
    \\    local IFS=$'\n'
    \\    # bash splits `--flag=value` at the `=`; join the pieces back into one word.
    \\    local -a words=()
    \\    local i n=0 joined=0
    \\    for ((i = 1; i <= COMP_CWORD; i++)); do
    \\        if [[ ${COMP_WORDS[i]} == "=" && $n -gt 0 && ${words[n-1]} == -* ]]; then
    \\            words[n-1]+="="; joined=1
    \\        elif ((joined)); then
    \\            words[n-1]+=${COMP_WORDS[i]}; joined=0
    \\        else
    \\            words[n]=${COMP_WORDS[i]}; n=$((n + 1))
    \\        fi
    \\    done
    \\    local full=${words[n-1]}
    \\    # What bash replaces is `cur`, the end of `full`; candidates lose the rest.
    \\    local strip=${full%"$cur"}
    \\    # The words before `full`, without a slice: bash 3.2 (macOS's) joins a slice into one
    \\    # word when IFS has no space.
    \\    local -a before=("${words[@]}") lines found
    \\    unset 'before[n-1]'
    \\    lines=($("@NAME@" __complete2 "${before[@]}" "$full" 2>/dev/null))
    \\    COMPREPLY=()
    \\    local line path prefix="" value=$full paths=0
    \\    for line in "${lines[@]}"; do
    \\        case $line in
    \\            ":prefix "*) prefix=${line#:prefix }; value=${full#"$prefix"} ;;
    \\            :dirs | :files | ":file "*)
    \\                paths=1
    \\                case $line in
    \\                    :dirs) found=($(compgen -d -- "$value" | LC_ALL=C sort)) ;;
    \\                    :files) found=($(compgen -f -- "$value" | LC_ALL=C sort)) ;;
    \\                    *) found=($(compgen -f -X "!*.${line#:file }" -- "$value" \
    \\                        | LC_ALL=C sort)) ;;
    \\                esac
    \\                for path in "${found[@]}"; do
    \\                    # Behind a prefix, bash cannot tell a directory: mark it here.
    \\                    [[ -n $prefix && -d $path ]] && path+=/
    \\                    COMPREPLY+=("${prefix#"$strip"}$path")
    \\                done
    \\                ;;
    \\            *) line=${line%%$'\t'*}; COMPREPLY+=("${line#"$strip"}") ;;
    \\        esac
    \\    done
    \\    if [[ -n $prefix ]]; then
    \\        compopt -o nospace 2>/dev/null
    \\    elif ((paths)); then
    \\        compopt -o filenames 2>/dev/null
    \\    fi
    \\    return 0
    \\}
    \\complete -o default -F _@IDENT@_complete @NAME@
    \\
;

const zsh_script =
    \\#compdef @NAME@
    \\# zsh completion for @NAME@. Load with:
    \\#   source <(@GENERATOR@)
    \\_@IDENT@() {
    \\    local -a lines items patterns
    \\    local line value description prefix="" dirs=0 files=0
    \\    lines=("${(@f)$("@NAME@" __complete2 "${(@)words[2,CURRENT-1]}" \
    \\        "${words[CURRENT]}" 2>/dev/null)}")
    \\    for line in $lines; do
    \\        case $line in
    \\            "") ;;
    \\            ":prefix "*) prefix=${line#:prefix } ;;
    \\            :dirs) dirs=1 ;;
    \\            :files) files=1 ;;
    \\            ":file "*) patterns+=("${line#:file }") ;;
    \\            *)
    \\                value=${line%%$'\t'*}
    \\                description=${line#*$'\t'}
    \\                [[ $description == $line ]] && description=""
    \\                items+=("${value//:/\\:}:$description")
    \\                ;;
    \\        esac
    \\    done
    \\    (( ${#items} )) && _describe -t values '@NAME@' items
    \\    # Paths after a `--flag=`: complete what follows it, keeping it in front.
    \\    if [[ -n $prefix && $PREFIX == ${(b)prefix}* ]]; then
    \\        IPREFIX+=$prefix
    \\        PREFIX=${PREFIX#${(b)prefix}}
    \\    fi
    \\    if (( ${#patterns} )); then
    \\        _files -g "*.(${(j:|:)patterns})"
    \\    elif (( files )); then
    \\        _files
    \\    elif (( dirs )); then
    \\        _files -/
    \\    elif (( ! ${#items} )); then
    \\        _files
    \\    fi
    \\}
    \\compdef _@IDENT@ @NAME@
    \\
;

const fish_script =
    \\# fish completion for @NAME@. Load with:
    \\#   @GENERATOR@ | source
    \\function __@IDENT@_complete
    \\    set -l tokens (commandline -opc)
    \\    set -l current (commandline -ct)
    \\    set -l prefix ''
    \\    set -l value $current
    \\    for line in (@NAME@ __complete2 $tokens[2..-1] $current 2>/dev/null)
    \\        switch $line
    \\            case ':prefix *'
    \\                set prefix (string sub -s 9 -- $line)
    \\                set value (string sub -s (math (string length -- $prefix) + 1) -- $current)
    \\            case :dirs
    \\                set -l found $value*/
    \\                printf '%s\n' $prefix$found
    \\            case :files
    \\                set -l found $value*
    \\                printf '%s\n' $prefix$found
    \\            case ':file *'
    \\                set -l found $value*.(string sub -s 7 -- $line)
    \\                printf '%s\n' $prefix$found
    \\            case '*'
    \\                printf '%s\n' $line
    \\        end
    \\    end
    \\end
    \\complete -c @NAME@ -f -n 'test (count (__@IDENT@_complete)) -gt 0' \
    \\    -a '(__@IDENT@_complete)'
    \\complete -c @NAME@ -F -n 'test (count (__@IDENT@_complete)) -eq 0'
    \\
;

const powershell_script =
    \\# PowerShell completion for @NAME@. Load with:
    \\#   @GENERATOR@ | Out-String | Invoke-Expression
    \\Register-ArgumentCompleter -Native -CommandName '@NAME@' -ScriptBlock {
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\    $words = @($commandAst.CommandElements | Select-Object -Skip 1 |
    \\        ForEach-Object { $_.ToString() })
    \\    # The word being completed is not passed as an element; @() keeps a single
    \\    # remaining word an array, which @words would otherwise splat by character.
    \\    if ($wordToComplete -ne '' -and $words.Count -gt 0) {
    \\        $words = @($words | Select-Object -SkipLast 1)
    \\    }
    \\    $prefix = ''
    \\    $value = $wordToComplete
    \\    & '@NAME@' __complete2 @words "$wordToComplete" 2>$null | ForEach-Object {
    \\        $line = $_
    \\        if ($line.StartsWith(':prefix ')) {
    \\            $prefix = $line.Substring(8)
    \\            $from = [Math]::Min($prefix.Length, $wordToComplete.Length)
    \\            $value = $wordToComplete.Substring($from)
    \\            return
    \\        }
    \\        if ($line.StartsWith(':')) {
    \\            $paths = switch -Wildcard ($line) {
    \\                ':dirs' { Get-ChildItem -Path "$value*" -Directory }
    \\                ':files' { Get-ChildItem -Path "$value*" -File }
    \\                ':file *' {
    \\                    Get-ChildItem -Path "$value*.$($line.Substring(6))" -File
    \\                }
    \\            }
    \\            $dir = Split-Path -Parent $value
    \\            foreach ($path in $paths) {
    \\                $name = if ($dir) { Join-Path $dir $path.Name } else { $path.Name }
    \\                $text = "$prefix$name"
    \\                [System.Management.Automation.CompletionResult]::new(
    \\                    $text, $text, 'ProviderItem', $text)
    \\            }
    \\            return
    \\        }
    \\        $parts = $line -split "`t", 2
    \\        $description = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $parts[0] }
    \\        [System.Management.Automation.CompletionResult]::new(
    \\            $parts[0], $parts[0], 'ParameterValue', $description)
    \\    }
    \\}
    \\
;

/// A `completion` command with one subcommand per shell, which print the script. Mount it
/// wherever it belongs in a tree; `App` mounts it on the root unless told not to. Scripts
/// always call `<app> __complete2`, which `App` answers at the root.
pub const command = spec.command(.{
    .name = "completion",
    .summary = "Print a shell completion script",
    .description =
    \\Print a script that makes the shell complete this program's commands, flags, and
    \\flag values. Each shell's subcommand says how to load it; "install" puts it where
    \\the shell loads it by itself.
    ,
    .subcommands = .{
        shellCommand(.bash, "source <(<this command>)"),
        shellCommand(.zsh, "source <(<this command>)"),
        shellCommand(.fish, "<this command> | source"),
        shellCommand(.powershell, "<this command> | Out-String | Invoke-Expression"),
        install_command,
    },
});

const InstallArgs = struct {
    shell: ?Shell = null,
};
const install_args = sets.args(InstallArgs, field.Set(.{field.Spec(InstallArgs){ .fields = .{
    .shell = .{ .help = "The shell (default: the one $SHELL names)" },
} }}), .{});

const install_command = spec.command(.{
    .name = "install",
    .summary = "Install the completion script for your shell",
    .description =
    \\Write the completion script where the shell loads it by itself:
    \\
    \\  bash  $XDG_DATA_HOME/bash-completion/completions/<app> (with bash-completion)
    \\  zsh   ~/.zfunc/_<app> (~/.zfunc must be in fpath, before compinit)
    \\  fish  $XDG_CONFIG_HOME/fish/completions/<app>.fish
    \\
    \\Without a shell, uses the one $SHELL names. PowerShell has no such place; the
    \\command says what to add to $PROFILE instead. Run it again after an update.
    ,
    .args = install_args,
    .dry_run = true,
    .run = runInstall,
});

fn runInstall(ctx: *Context, args: InstallArgs) !void {
    const shell = args.shell orelse detected: {
        const login = ctx.environ.get("SHELL") orelse "";
        break :detected Shell.fromName(std.fs.path.basename(login)) orelse
            return ctx.usageError("cannot tell the shell from $SHELL; name it", .{});
    };
    var generator: std.Io.Writer.Allocating = .init(ctx.arena);
    try help.writePath(&generator.writer, ctx.path[0 .. ctx.path.len - 1]);
    try generator.writer.print(" {t}", .{shell});
    if (shell == .powershell) {
        return ctx.fail("PowerShell loads completions from $PROFILE; add this line to it:\n" ++
            "  {s} | Out-String | Invoke-Expression", .{generator.written()});
    }
    const target = try installPath(ctx.arena, ctx.environ, shell, ctx.app_name) orelse
        return ctx.fail("$HOME is not set; cannot tell where the script goes", .{});
    if (ctx.dry_run) return ctx.out.print("would write {s}\n", .{target});
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    try script(&text.writer, shell, ctx.app_name, generator.written());
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(target)) |parent| try cwd.createDirPath(ctx.io, parent);
    try cwd.writeFile(ctx.io, .{ .sub_path = target, .data = text.written() });
    try ctx.out.print("wrote {s}\n", .{target});
    if (shell == .zsh) {
        try ctx.out.writeAll("If ~/.zfunc is not in fpath yet, add this to ~/.zshrc, " ++
            "before compinit:\n  fpath=(~/.zfunc $fpath)\n");
    }
}

/// Where `shell` loads completion scripts from by itself; null without `$HOME`.
fn installPath(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    shell: Shell,
    app_name: []const u8,
) Allocator.Error!?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    const join = std.fs.path.join;
    return switch (shell) {
        .bash => if (environ.get("XDG_DATA_HOME")) |data|
            try join(arena, &.{ data, "bash-completion", "completions", app_name })
        else
            try join(arena, &.{ home, ".local/share/bash-completion/completions", app_name }),
        .zsh => try join(arena, &.{
            environ.get("ZDOTDIR") orelse home,
            ".zfunc",
            try std.mem.concat(arena, u8, &.{ "_", app_name }),
        }),
        .fish => try join(arena, &.{
            environ.get("XDG_CONFIG_HOME") orelse try join(arena, &.{ home, ".config" }),
            "fish",
            "completions",
            try std.mem.concat(arena, u8, &.{ app_name, ".fish" }),
        }),
        .powershell => null,
    };
}

fn shellCommand(comptime shell: Shell, comptime how: []const u8) Command {
    return spec.command(.{
        .name = @tagName(shell),
        .summary = "Print the " ++ @tagName(shell) ++ " completion script",
        .description = "Print the " ++ @tagName(shell) ++ " completion script. " ++
            "Load it with:\n\n  " ++ how ++
            "\n\nThe first lines of the script name the exact command.",
        .run = struct {
            fn run(ctx: *Context) !void {
                var buffer: [256]u8 = undefined;
                var generator: Writer = .fixed(&buffer);
                // A path longer than the buffer only shortens the comment in the script.
                help.writePath(&generator, ctx.path) catch {};
                try script(ctx.out, shell, ctx.app_name, generator.buffered());
            }
        }.run,
    });
}

/// `my-app` -> `my_app`, for shell function names.
fn identifier(buffer: []u8, name: []const u8) []const u8 {
    const len = @min(buffer.len, name.len);
    for (name[0..len], buffer[0..len]) |c, *out| {
        out.* = if (std.ascii.isAlphanumeric(c)) c else '_';
    }
    return buffer[0..len];
}

const testing = std.testing;

fn noop(_: *Context) !void {}

const test_root = spec.command(.{
    .name = "app",
    .persistent_flags = flags: {
        const T = struct {
            output: enum { text, json } = .text,
        };
        break :flags sets.flags(
            T,
            field.Set(.{field.Spec(T){ .fields = .{ .output = .{ .help = "Output format" } } }}),
            .{ .fields = .{ .output = .{ .short = 'o' } } },
        );
    },
    .subcommands = .{
        spec.command(.{
            .name = "serve",
            .summary = "Start",
            .flags = sets.flags(struct {
                port: u16 = 1,
                hidden_one: bool = false,
            }, field.none, .{ .fields = .{ .hidden_one = .{ .hidden = true } } }),
            .args = .{ .max = 1 },
            .run = noop,
        }),
        spec.command(.{ .name = "status", .summary = "Show status", .run = noop }),
        spec.command(.{ .name = "secret", .hidden = true, .run = noop }),
    },
});

fn complete(words: []const []const u8) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try candidates(&out.writer, &test_root, words, .{});
    return out.toOwnedSlice();
}

fn expectCompletion(words: []const []const u8, expected: []const u8) !void {
    const got = try complete(words);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "subcommands by prefix, built-ins on the root" {
    try expectCompletion(
        &.{""},
        "serve\tStart\nstatus\tShow status\nhelp\tHelp about any command\n",
    );
    try expectCompletion(&.{"s"}, "serve\tStart\nstatus\tShow status\n");
    try expectCompletion(&.{ "serve", "" }, "");
}

test "flags, visible from the current command" {
    try expectCompletion(
        &.{ "serve", "--" },
        "--port\t\n--output\tOutput format\n--help\tShow help\n",
    );
    try expectCompletion(&.{ "serve", "--p" }, "--port\t\n");
    try expectCompletion(&.{"--o"}, "--output\tOutput format\n");
}

test "enum values after a flag" {
    try expectCompletion(&.{ "--output", "" }, "text\njson\n");
    try expectCompletion(&.{ "serve", "-o", "j" }, "json\n");
    try expectCompletion(&.{ "serve", "--output=t" }, "--output=text\n");
    try expectCompletion(&.{ "serve", "--port", "" }, "");
    try expectCompletion(&.{ "--output", "json", "st" }, "status\tShow status\n");
}

test "scripts name the program" {
    for (std.enums.values(Shell)) |shell| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try script(&out.writer, shell, "my-app", "my-app completion x");
        try testing.expect(std.mem.indexOf(u8, out.written(), "__complete") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "my-app") != null);
    }
    try testing.expectEqual(Shell.zsh, Shell.fromName("zsh").?);
    try testing.expectEqual(null, Shell.fromName("tcsh"));
}

test "after --, nothing but files" {
    try expectCompletion(&.{ "--", "" }, "");
    try expectCompletion(&.{ "--", "s" }, "");
    try expectCompletion(&.{ "serve", "--", "--p" }, "");
}

test "short flags: a value in the next word or in the same one" {
    try expectCompletion(&.{ "-o", "" }, "text\njson\n");
    // `-ojson` holds its value, so the next word is a command again.
    try expectCompletion(&.{ "-ojson", "st" }, "status\tShow status\n");
    try expectCompletion(&.{ "-o=json", "st" }, "status\tShow status\n");
}

test "a bundle ending in a flag that takes a value completes the value" {
    const root = comptime spec.command(.{
        .name = "app",
        .flags = sets.flags(struct {
            verbose: bool = false,
            output: enum { text, json } = .text,
        }, field.none, .{
            .fields = .{ .verbose = .{ .short = 'v' }, .output = .{ .short = 'o' } },
        }),
        .run = noop,
    });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try candidates(&out.writer, &root, &.{ "-vo", "j" }, .{ .help_command = false });
    try testing.expectEqualStrings("json\n", out.written());
    out.clearRetainingCapacity();
    try candidates(&out.writer, &root, &.{ "-vojson", "" }, .{ .help_command = false });
    try testing.expectEqualStrings("", out.written());
}

test "hidden flags are not offered, a shadowed one is offered once" {
    try expectCompletion(&.{ "serve", "--h" }, "--help\tShow help\n");
    const root = comptime spec.command(.{
        .name = "app",
        .persistent_flags = struct { name: []const u8 = "" },
        .subcommands = .{spec.command(.{
            .name = "sub",
            .flags = flags: {
                const T = struct {
                    name: []const u8 = "",
                };
                break :flags sets.flags(
                    T,
                    field.Set(.{field.Spec(T){ .fields = .{ .name = .{ .help = "Sub name" } } }}),
                    .{},
                );
            },
            .run = noop,
        })},
    });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try candidates(&out.writer, &root, &.{ "sub", "--n" }, .{ .help_command = false });
    try testing.expectEqualStrings("--name\tSub name\n", out.written());
}

test "deprecated commands and flags are not offered" {
    const root = comptime spec.command(.{
        .name = "app",
        .flags = flags: {
            const T = struct {
                colour: bool = false,
                color: bool = false,
            };
            break :flags sets.flags(
                T,
                field.Set(
                    .{field.Spec(T){ .fields = .{ .colour = .{ .deprecated = "use --color" } } }},
                ),
                .{},
            );
        },
        .subcommands = .{
            spec.command(.{ .name = "remove", .deprecated = "use delete", .run = noop }),
            spec.command(.{ .name = "delete", .summary = "Delete", .run = noop }),
        },
    });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const options: Options = .{ .help_command = false };
    try candidates(&out.writer, &root, &.{""}, options);
    try testing.expectEqualStrings("delete\tDelete\n", out.written());
    out.clearRetainingCapacity();
    try candidates(&out.writer, &root, &.{"--col"}, options);
    try testing.expectEqualStrings("--color\t\n", out.written());
}

test "after a positional, no commands are offered" {
    try expectCompletion(&.{ "serve", "dir", "" }, "");
    try expectCompletion(&.{ "serve", "dir", "--p" }, "--port\t\n");
}

const App = @import("App.zig");
const cli_testing = @import("testing.zig");

const mounted_root = spec.command(.{
    .name = "app",
    .subcommands = .{spec.command(.{
        .name = "tools",
        .subcommands = .{command},
    })},
});

test "completion mounted under a nested command names its full path" {
    const app: App = .{ .root = &mounted_root, .completion_command = false };

    const top = try cli_testing.run(app, &.{ "completion", "bash" }, .{});
    defer top.deinit();
    try testing.expectEqual(2, top.status);

    for (std.enums.values(Shell)) |shell| {
        const r = try cli_testing.run(app, &.{ "tools", "completion", @tagName(shell) }, .{});
        defer r.deinit();
        try testing.expectEqual(0, r.status);
        var expected_buffer: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "app tools completion {s}",
            .{@tagName(shell)},
        );
        const first_lines = r.out[0 .. std.mem.indexOf(u8, r.out, "\n\n") orelse
            @min(r.out.len, 200)];
        try testing.expect(std.mem.indexOf(u8, first_lines, expected) != null);
        try testing.expect(std.mem.indexOf(u8, r.out, "__complete") != null);
    }

    // `__complete` is answered at the root, and walks into the mount.
    const words = try cli_testing.run(app, &.{ "__complete", "tools", "completion", "z" }, .{});
    defer words.deinit();
    try testing.expectEqualStrings("zsh\tPrint the zsh completion script\n", words.out);
}

test identifier {
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("my_a", identifier(&buffer, "my-app"));
}

test "a lone dash offers flags; an unknown --flag= offers nothing" {
    try expectCompletion(&.{"-"}, "--output\tOutput format\n--help\tShow help\n");
    try expectCompletion(&.{"--nope="}, "");
    try expectCompletion(&.{ "serve", "--port=" }, "");
}

const ColorFlags = struct {
    palette: []const u8 = "warm",
    color: ?[]const u8 = null,
};
const color_flags = sets.flags(ColorFlags, field.none, .{ .fields = .{
    .color = .{ .complete = .from(completeColor) },
} });

/// Offers colors from the palette chosen earlier on the line.
fn completeColor(ctx: *Context, prefix: []const u8) ![]const Command.Candidate {
    _ = prefix;
    const flags = try ctx.flags(ColorFlags);
    if (std.mem.eql(u8, flags.palette, "warm")) {
        return &.{ .{ .value = "red", .description = "warm" }, .{ .value = "orange" } };
    }
    return &.{ .{ .value = "blue" }, .{ .value = "green" } };
}

/// Offers names after what is already typed, numbered by position.
fn completeName(ctx: *Context, prefix: []const u8) ![]const Command.Candidate {
    _ = prefix;
    const first: []const Command.Candidate = &.{ .{ .value = "ann" }, .{ .value = "bob" } };
    const second: []const Command.Candidate = &.{.{ .value = "second" }};
    return if (ctx.args.len == 0) first else second;
}

fn completeNothing(ctx: *Context, prefix: []const u8) ![]const Command.Candidate {
    _ = ctx;
    _ = prefix;
    return error.Broken;
}

fn paint(ctx: *Context) !void {
    _ = ctx;
}

const completer_root = spec.command(.{
    .name = "app",
    .subcommands = .{
        spec.command(.{ .name = "paint", .flags = color_flags, .run = paint }),
        spec.command(.{
            .name = "greet",
            .args = .{ .min = 2, .max = 2, .complete = completeName },
            .run = paint,
            .flags = color_flags,
        }),
        // `.complete` may also be a pointer to the function.
        spec.command(.{
            .name = "broken",
            .args = .{ .max = 1, .complete = &completeNothing },
            .run = paint,
        }),
    },
});

fn expectCustom(words: []const []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try candidates(&out.writer, &completer_root, words, .{
        .help_command = false,
        .runtime = .{
            .io = testing.io,
            .gpa = testing.allocator,
            .arena = arena.allocator(),
            .environ = &environ,
            .app_name = "app",
        },
    });
    try testing.expectEqualStrings(expected, out.written());
}

test "a flag's completer sees the flags before it" {
    try expectCustom(&.{ "paint", "--color", "" }, "red\twarm\norange\n");
    try expectCustom(&.{ "paint", "--palette", "cool", "--color", "" }, "blue\ngreen\n");
    try expectCustom(&.{ "paint", "--palette=cool", "--color", "g" }, "green\n");
    try expectCustom(&.{ "paint", "--palette", "cool", "--color=b" }, "--color=blue\n");
}

test "a positional completer knows which argument it completes" {
    try expectCustom(&.{ "greet", "" }, "ann\nbob\n");
    try expectCustom(&.{ "greet", "a" }, "ann\n");
    try expectCustom(&.{ "greet", "--palette", "x", "ann", "" }, "second\n");
    // A required argument still missing does not stop completion of the first.
    try expectCustom(&.{ "greet", "-" }, "--palette\t\n--color\t\n--help\tShow help\n");
}

test "a failing completer offers nothing" {
    try expectCustom(&.{ "broken", "" }, "");
}

test "without a runtime, completers are not called" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try candidates(&out.writer, &completer_root, &.{ "greet", "" }, .{});
    try testing.expectEqualStrings("", out.written());
}

test "completion descends through an unambiguous prefix when the app accepts one" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const words: []const []const u8 = &.{ "ser", "--p" };
    try candidates(&out.writer, &test_root, words, .{ .help_command = false });
    try testing.expectEqualStrings("", out.written());
    out.clearRetainingCapacity();
    try candidates(&out.writer, &test_root, words, .{ .prefix_matching = true });
    try testing.expectEqualStrings("--port\t\n", out.written());
}

test "install writes each shell's script where it loads it, named after the app" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    const app: App = .{ .root = &mounted_root, .completion_command = false };
    const env: []const [2][]const u8 = &.{ .{ "HOME", home }, .{ "SHELL", "/bin/zsh" } };
    const zsh = try cli_testing.run(app, &.{ "tools", "completion", "install" }, .{ .env = env });
    defer zsh.deinit();
    try testing.expectEqual(0, zsh.status);
    const script_text =
        try tmp.dir.readFileAlloc(testing.io, ".zfunc/_app", testing.allocator, .unlimited);
    defer testing.allocator.free(script_text);
    try testing.expect(std.mem.indexOf(u8, script_text, "app tools completion zsh") != null);

    const dry_args: []const []const u8 =
        &.{ "tools", "completion", "install", "fish", "--dry-run" };
    const dry = try cli_testing.run(app, dry_args, .{ .env = env });
    defer dry.deinit();
    // A native path: it is where the file goes, not something the user wrote.
    const sep = std.fs.path.sep_str;
    const fish = sep ++ ".config" ++ sep ++ "fish" ++ sep ++ "completions" ++ sep ++ "app.fish\n";
    try testing.expect(std.mem.endsWith(u8, dry.out, fish));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".config", .{}));

    const no_shell: []const [2][]const u8 = &.{.{ "HOME", home }};
    const unknown = try cli_testing.run(app, &.{ "tools", "completion", "install" }, .{
        .env = no_shell,
    });
    defer unknown.deinit();
    try testing.expectEqual(2, unknown.status);
}
