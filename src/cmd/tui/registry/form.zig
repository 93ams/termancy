//! A form, as huh builds them: labeled fields filled in one after another, each checked
//! before the form is submitted, on one page or several.
//!
//! ```zig
//! var fields = [_]Field{
//!     .{ .label = "Name", .kind = .{ .input = .{ .gpa = gpa } }, .required = true },
//!     .{ .label = "Plan", .kind = .{ .choice = .{ .options = &.{ "free", "pro" } } } },
//!     .{ .label = "Region", .kind = .{ .select = .{ .options = &.{ "eu", "us", "ap" } } } },
//!     .{ .label = "Extras", .kind = .{ .multi_select = .{ .options = &.{ "ssl", "cdn" } } } },
//!     .{ .label = "Agree?", .kind = .{ .confirm = .{} } },
//! };
//! defer for (&fields) |*field| field.deinit();
//! var form: Form = .{ .fields = &fields };
//! _ = try tui.run(gpa, io, &form, .{ .environ = environ });
//! // then fields[i].kind.input.value(), fields[i].kind.select.selected(), ...
//! ```
//!
//! Fields: `input` (a line of text, see `input`), `text` (several lines, see `textarea`),
//! `choice` (a few options on one line), `select` (options in a list, filtered by typing
//! after `/`), `multi_select` (several options, up to a limit), `confirm` (yes or no),
//! `file` (a `filepicker`), and `note` (text to read, which takes no answer).
//!
//! Keys: tab moves to the next field and shift+tab to the previous one (skipping notes and
//! hidden fields); enter moves on when the field is valid, and on the last field of the
//! last page submits once every field is; esc cancels. Up and down move between fields,
//! except in a select, a multi-select, a text, or a file picker, where they move inside it.
//! On a choice, left and right pick an option and space cycles; in a multi-select, space
//! or x toggles an option; a confirm takes left and right, y and n; a text takes enter to
//! move on and alt+enter (or ctrl+j) for a new line. An input is valid when it is filled
//! in (if `required`) and its `validate` accepts it; a multi-select when it has at least
//! `min` options; the others always are. The first invalid field takes the focus and says
//! why.
//!
//! Pages (`pages`) split the fields into groups, each with an optional title, shown one at
//! a time; `layout` shows them stacked or in columns instead. A field's `hide` decides,
//! from the form, whether it is asked at all (huh's `WithHideFunc`): a follow-up only for
//! some answers. Styles come in themes: `Styles.charm` (the default), `dracula`,
//! `catppuccin`, `base16`, and `base`.
//!
//! The fields are borrowed: the form points at the caller's array, which must outlive it.

const std = @import("std");
const tui = @import("tui");
const Writer = std.Io.Writer;
const Input = @import("input.zig").Input;
const Textarea = @import("textarea.zig").Textarea;
const FilePicker = @import("filepicker.zig").FilePicker;

pub const Status = enum { active, submitted, canceled };

pub const Field = struct {
    label: []const u8,
    /// Dimmed text under the label; none when empty.
    description: []const u8 = "",
    kind: Kind,
    /// Whether an input or a text must be filled in.
    required: bool = false,
    /// Leaves the field out (not shown, not asked, not checked) while this says so.
    hide: ?*const fn (form: *const Form) bool = null,

    pub const Kind = union(enum) {
        input: Input,
        text: Textarea,
        choice: Choice,
        select: Select,
        multi_select: MultiSelect,
        confirm: Confirm,
        file: *FilePicker,
        note,
    };

    /// Frees what an input or a text typed.
    pub fn deinit(field: *Field) void {
        switch (field.kind) {
            .input => |*input| input.deinit(),
            .text => |*area| area.deinit(),
            else => {},
        }
    }

    fn takesFocus(field: *const Field) bool {
        return field.kind != .note;
    }
};

/// One of `options`, all shown on one line.
pub const Choice = struct {
    options: []const []const u8,
    index: usize = 0,

    pub fn selected(choice: Choice) []const u8 {
        return choice.options[choice.index];
    }
};

/// One of `options`, in a list `height` rows high, narrowed by typing after `/`.
pub const Select = struct {
    options: []const []const u8,
    index: usize = 0,
    height: usize = 5,
    /// The first option shown.
    offset: usize = 0,
    /// What was typed after `/`, while filtering.
    filter: [64]u8 = undefined,
    filter_len: usize = 0,
    filtering: bool = false,

    pub fn selected(s: *const Select) []const u8 {
        return s.options[s.index];
    }

    fn query(s: *const Select) []const u8 {
        return s.filter[0..s.filter_len];
    }

    fn visible(s: *const Select, i: usize) bool {
        if (s.filter_len == 0) return true;
        return std.ascii.findIgnoreCase(s.options[i], s.query()) != null;
    }

    fn move(s: *Select, forward: bool) void {
        var i = s.index;
        while (true) {
            if (forward) {
                if (i + 1 >= s.options.len) return;
                i += 1;
            } else {
                if (i == 0) return;
                i -= 1;
            }
            if (s.visible(i)) break;
        }
        s.index = i;
        if (s.index < s.offset) s.offset = s.index;
        if (s.index >= s.offset + s.height) s.offset = s.index + 1 - s.height;
    }

    /// After the filter changed: the cursor on the first option that still matches.
    fn refilter(s: *Select) void {
        if (s.visible(s.index)) return;
        for (0..s.options.len) |i| if (s.visible(i)) {
            s.index = i;
            s.offset = i;
            return;
        };
    }

    fn handleKey(s: *Select, key: tui.input.Key) bool {
        if (s.filtering) {
            if (key.matches("enter") or key.matches("esc")) {
                s.filtering = false;
                if (key.matches("esc")) s.filter_len = 0;
                return true;
            }
            if (key.matches("backspace")) {
                s.filter_len -|= 1;
                s.refilter();
                return true;
            }
            if (key.printable()) |c| {
                if (c < 0x80 and s.filter_len < s.filter.len) {
                    s.filter[s.filter_len] = @intCast(c);
                    s.filter_len += 1;
                    s.refilter();
                }
                return true;
            }
        }
        if (key.matches("down") or key.matches("j") or key.matches("ctrl+n")) {
            s.move(true);
        } else if (key.matches("up") or key.matches("k") or key.matches("ctrl+p")) {
            s.move(false);
        } else if (key.matches("/")) {
            s.filtering = true;
        } else return false;
        return true;
    }
};

/// Any of `options`, up to `limit`, at least `min`.
pub const MultiSelect = struct {
    options: []const []const u8,
    /// Which are chosen: a bit per option, so up to 64 options.
    chosen: u64 = 0,
    cursor: usize = 0,
    limit: ?usize = null,
    min: usize = 0,

    pub fn isChosen(m: *const MultiSelect, i: usize) bool {
        return m.chosen & (@as(u64, 1) << @intCast(i)) != 0;
    }

    pub fn count(m: *const MultiSelect) usize {
        return @popCount(m.chosen);
    }

    fn toggle(m: *MultiSelect, i: usize) void {
        const bit = @as(u64, 1) << @intCast(i);
        if (m.chosen & bit != 0) {
            m.chosen &= ~bit;
        } else if (m.limit == null or m.count() < m.limit.?) {
            m.chosen |= bit;
        }
    }

    fn handleKey(m: *MultiSelect, key: tui.input.Key) bool {
        const last = @min(m.options.len, 64) -| 1;
        if (key.matches("down") or key.matches("j")) {
            m.cursor = @min(m.cursor + 1, last);
        } else if (key.matches("up") or key.matches("k")) {
            m.cursor -|= 1;
        } else if (key.matches("space") or key.matches("x")) {
            if (m.options.len > 0) m.toggle(m.cursor);
        } else return false;
        return true;
    }
};

/// Yes or no, as two buttons.
pub const Confirm = struct {
    value: bool = false,
    affirmative: []const u8 = "Yes",
    negative: []const u8 = "No",

    fn handleKey(c: *Confirm, key: tui.input.Key) bool {
        if (key.matches("left") or key.matches("h") or key.matches("right") or key.matches("l")) {
            c.value = !c.value;
        } else if (key.matches("y")) {
            c.value = true;
        } else if (key.matches("n")) {
            c.value = false;
        } else return false;
        return true;
    }
};

/// A group of fields shown together.
pub const Page = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    /// How many fields, in order from where the page before ended.
    count: usize,
};

/// How pages are shown.
pub const Layout = union(enum) {
    /// One page at a time.
    pages,
    /// Every page, one below another.
    stack,
    /// Every page, side by side in this many columns.
    columns: usize,
};

pub const Form = struct {
    fields: []Field,
    /// The field keys go to.
    focus: usize = 0,
    /// A line above the fields; none when empty.
    title: []const u8 = "",
    /// Groups of fields; empty puts every field on one page.
    pages: []const Page = &.{},
    layout: Layout = .pages,
    /// What a required field that is empty says.
    required_message: []const u8 = "This field is required",
    /// What a multi-select with too few options says.
    too_few_message: []const u8 = "Choose more",
    /// A line of key hints below the fields.
    show_help: bool = true,
    /// Columns a page takes in the `columns` layout.
    column_width: usize = 30,
    status: Status = .active,
    /// Why the focused field is not valid, for the kinds without a message of their own.
    problem: ?[]const u8 = null,
    styles: Styles = .charm,

    pub const Styles = struct {
        title: tui.Style,
        label: tui.Style,
        focused_label: tui.Style,
        description: tui.Style,
        /// The option a choice has, bracketed as well, so it shows under `NO_COLOR`.
        chosen: tui.Style,
        option: tui.Style,
        /// The cursor's row in a select or multi-select.
        cursor: tui.Style,
        /// The button a confirm has.
        button: tui.Style,
        blurred_button: tui.Style,
        @"error": tui.Style,
        help: tui.Style,
        /// The bar before the focused field.
        focus_bar: tui.Style,

        /// Charm's colors: pink, purple, and gray (huh's default).
        pub const charm: Styles = .{
            .title = .{ .fg = .{ .indexed = 99 }, .bold = true },
            .label = .{ .bold = true },
            .focused_label = .{ .fg = .{ .indexed = 212 }, .bold = true },
            .description = .{ .fg = .{ .indexed = 240 } },
            .chosen = .{ .fg = .{ .indexed = 212 }, .bold = true },
            .option = .{ .fg = .{ .indexed = 245 } },
            .cursor = .{ .fg = .{ .indexed = 212 } },
            .button = .{ .fg = .{ .indexed = 230 }, .bg = .{ .indexed = 212 } },
            .blurred_button = .{ .fg = .{ .indexed = 252 }, .bg = .{ .indexed = 237 } },
            .@"error" = .{ .fg = .{ .indexed = 203 } },
            .help = .{ .fg = .{ .indexed = 240 } },
            .focus_bar = .{ .fg = .{ .indexed = 99 } },
        };
        /// Dracula's palette.
        pub const dracula: Styles = .{
            .title = .{ .fg = .hex(0xbd93f9), .bold = true },
            .label = .{ .fg = .hex(0xf8f8f2), .bold = true },
            .focused_label = .{ .fg = .hex(0xf1fa8c), .bold = true },
            .description = .{ .fg = .hex(0x6272a4) },
            .chosen = .{ .fg = .hex(0xf1fa8c), .bold = true },
            .option = .{ .fg = .hex(0xf8f8f2) },
            .cursor = .{ .fg = .hex(0xf1fa8c) },
            .button = .{ .fg = .hex(0x282a36), .bg = .hex(0xbd93f9) },
            .blurred_button = .{ .fg = .hex(0xf8f8f2), .bg = .hex(0x44475a) },
            .@"error" = .{ .fg = .hex(0xff5555) },
            .help = .{ .fg = .hex(0x6272a4) },
            .focus_bar = .{ .fg = .hex(0xbd93f9) },
        };
        /// Catppuccin Mocha.
        pub const catppuccin: Styles = .{
            .title = .{ .fg = .hex(0xcba6f7), .bold = true },
            .label = .{ .fg = .hex(0xcdd6f4), .bold = true },
            .focused_label = .{ .fg = .hex(0xf5c2e7), .bold = true },
            .description = .{ .fg = .hex(0x6c7086) },
            .chosen = .{ .fg = .hex(0xf5c2e7), .bold = true },
            .option = .{ .fg = .hex(0xcdd6f4) },
            .cursor = .{ .fg = .hex(0xf5c2e7) },
            .button = .{ .fg = .hex(0x1e1e2e), .bg = .hex(0xcba6f7) },
            .blurred_button = .{ .fg = .hex(0xcdd6f4), .bg = .hex(0x313244) },
            .@"error" = .{ .fg = .hex(0xf38ba8) },
            .help = .{ .fg = .hex(0x6c7086) },
            .focus_bar = .{ .fg = .hex(0xcba6f7) },
        };
        /// The terminal's own 16 colors, so its theme decides.
        pub const base16: Styles = .{
            .title = .{ .fg = .blue, .bold = true },
            .label = .{ .bold = true },
            .focused_label = .{ .fg = .magenta, .bold = true },
            .description = .{ .fg = .bright_black },
            .chosen = .{ .fg = .magenta, .bold = true },
            .option = .{},
            .cursor = .{ .fg = .yellow },
            .button = .{ .fg = .black, .bg = .magenta },
            .blurred_button = .{ .bg = .bright_black },
            .@"error" = .{ .fg = .red },
            .help = .{ .fg = .bright_black },
            .focus_bar = .{ .fg = .bright_black },
        };
        /// No colors: bold labels and reverse buttons, for any terminal.
        pub const base: Styles = .{
            .title = .{ .bold = true },
            .label = .{},
            .focused_label = .{ .bold = true },
            .description = .{ .dim = true },
            .chosen = .{ .bold = true },
            .option = .{},
            .cursor = .{ .bold = true },
            .button = .{ .reverse = true },
            .blurred_button = .{},
            .@"error" = .{ .bold = true },
            .help = .{ .dim = true },
            .focus_bar = .{},
        };
    };

    /// Shows the cursor in the focused field only.
    pub fn start(form: *Form) tui.Cmd {
        if (!form.askable(form.focus)) {
            form.focus = form.nextField(form.focus, true) orelse form.focus;
        }
        form.focusOn(form.focus);
        return .none;
    }

    /// Whether field `i` takes answers now: it takes focus and is not hidden.
    fn askable(form: *const Form, i: usize) bool {
        const field = &form.fields[i];
        if (!field.takesFocus()) return false;
        if (field.hide) |hide| if (hide(form)) return false;
        return true;
    }

    /// The next (or previous) field that takes answers, or null at the end.
    fn nextField(form: *const Form, from: usize, forward: bool) ?usize {
        var i = from;
        while (true) {
            if (forward) {
                if (i + 1 >= form.fields.len) return null;
                i += 1;
            } else {
                if (i == 0) return null;
                i -= 1;
            }
            if (form.askable(i)) return i;
        }
    }

    /// The page field `index` is on.
    pub fn pageOf(form: *const Form, index: usize) usize {
        var end: usize = 0;
        for (form.pages, 0..) |page, p| {
            end += page.count;
            if (index < end) return p;
        }
        return form.pages.len -| 1;
    }

    /// The range of fields on page `page`.
    fn pageRange(form: *const Form, page: usize) struct { start: usize, end: usize } {
        if (form.pages.len == 0) return .{ .start = 0, .end = form.fields.len };
        var first: usize = 0;
        for (form.pages[0..page]) |p| first += p.count;
        return .{ .start = first, .end = @min(first + form.pages[page].count, form.fields.len) };
    }

    pub fn update(form: *Form, msg: tui.Msg) tui.Cmd {
        if (form.fields.len == 0) return .none;
        switch (msg) {
            .key => |key| return form.handleKey(key),
            .paste => |text| switch (form.fields[form.focus].kind) {
                .input => |*input| input.insert(text) catch {},
                .text => |*area| area.insert(text) catch {},
                else => {},
            },
            else => switch (form.fields[form.focus].kind) {
                .file => |picker| return form.filePicked(picker.update(msg)),
                else => {},
            },
        }
        return .none;
    }

    fn handleKey(form: *Form, key: tui.input.Key) tui.Cmd {
        const field = &form.fields[form.focus];
        // A select being filtered takes every key until enter or esc ends the filter.
        if (field.kind == .select and field.kind.select.filtering) {
            _ = field.kind.select.handleKey(key);
            return .none;
        }
        if (key.matches("esc")) {
            form.status = .canceled;
            return .quit;
        }
        if (key.matches("tab")) return form.advance(false);
        if (key.matches("shift+tab")) return form.back();
        if (field.kind == .text and (key.matches("alt+enter") or key.matches("ctrl+j"))) {
            field.kind.text.insert("\n") catch {};
            return .none;
        }
        if (key.matches("enter")) return form.advance(true);
        switch (field.kind) {
            .input => |*input| {
                if (key.matches("down")) return form.advance(false);
                if (key.matches("up")) return form.back();
                _ = input.handleKey(key);
            },
            .text => |*area| _ = area.handleKey(key),
            .choice => |*choice| {
                if (key.matches("down")) return form.advance(false);
                if (key.matches("up")) return form.back();
                const count = choice.options.len;
                if (key.matches("left") or key.matches("h")) {
                    choice.index -|= 1;
                } else if (key.matches("right") or key.matches("l")) {
                    choice.index = @min(choice.index + 1, count -| 1);
                } else if (key.matches("space") and count > 0) {
                    choice.index = (choice.index + 1) % count;
                }
            },
            .select => |*s| _ = s.handleKey(key),
            .multi_select => |*m| {
                _ = m.handleKey(key);
                form.problem = null;
            },
            .confirm => |*c| {
                if (key.matches("down")) return form.advance(false);
                if (key.matches("up")) return form.back();
                _ = c.handleKey(key);
            },
            .file => |picker| return form.filePicked(picker.update(.{ .key = key })),
            .note => {},
        }
        return .none;
    }

    /// After the file picker had a message: on to the next field once it chose a file.
    fn filePicked(form: *Form, cmd: tui.Cmd) tui.Cmd {
        const picker = form.fields[form.focus].kind.file;
        if (cmd.len > 0 and cmd.slice()[0] == .quit) {
            if (picker.status == .canceled) {
                form.status = .canceled;
                return .quit;
            }
            return form.advance(true);
        }
        return cmd;
    }

    /// Moves to the next field (checking this one first with `check`), the next page, or
    /// submits from the last.
    fn advance(form: *Form, checked: bool) tui.Cmd {
        if (checked and !form.validField(form.focus)) return .none;
        if (form.nextField(form.focus, true)) |next| {
            const crossing = form.layout == .pages and form.pages.len > 0 and
                form.pageOf(next) != form.pageOf(form.focus);
            // A page is checked whole before the next one shows.
            const page = form.pageRange(form.pageOf(form.focus));
            if (crossing and !form.checkRange(page)) return .none;
            form.focusOn(next);
            return .none;
        }
        if (!checked) return .none;
        return form.submit();
    }

    fn back(form: *Form) tui.Cmd {
        if (form.nextField(form.focus, false)) |previous| form.focusOn(previous);
        return .none;
    }

    fn checkRange(form: *Form, range: anytype) bool {
        for (range.start..range.end) |i| {
            if (form.askable(i) and !form.validField(i)) {
                form.focusOn(i);
                _ = form.validField(i);
                return false;
            }
        }
        return true;
    }

    /// Checks every field; submits and quits when all pass, otherwise focuses the first
    /// that does not.
    pub fn submit(form: *Form) tui.Cmd {
        var first_invalid: ?usize = null;
        for (0..form.fields.len) |i| {
            if (!form.askable(i)) continue;
            if (!form.check(i) and first_invalid == null) first_invalid = i;
        }
        if (first_invalid) |i| {
            form.focusOn(i);
            _ = form.validField(i);
            return .none;
        }
        form.status = .submitted;
        return .quit;
    }

    /// `check`, and for kinds without a message of their own, `problem` set or cleared.
    fn validField(form: *Form, index: usize) bool {
        const ok = form.check(index);
        if (index == form.focus) {
            const counted = form.fields[index].kind == .multi_select;
            form.problem = if (ok or !counted) null else form.too_few_message;
            if (!ok and form.fields[index].kind == .text) form.problem = form.required_message;
        }
        return ok;
    }

    /// Checks field `index`, recording its message; returns whether it is valid.
    pub fn check(form: *Form, index: usize) bool {
        const field = &form.fields[index];
        switch (field.kind) {
            .input => |*input| {
                if (field.required and input.value().len == 0) {
                    input.message = form.required_message;
                    return false;
                }
                return input.check();
            },
            .text => |*area| return !field.required or area.value().len > 0,
            .multi_select => |*m| return m.count() >= m.min,
            .file => |picker| return !field.required or picker.chosen != null,
            else => return true,
        }
    }

    fn focusOn(form: *Form, index: usize) void {
        form.focus = index;
        form.problem = null;
        for (form.fields, 0..) |*field, i| switch (field.kind) {
            .input => |*input| input.focused = i == index,
            .text => |*area| area.focused = i == index,
            else => {},
        };
    }

    pub fn view(form: *const Form, w: *Writer) Writer.Error!void {
        if (form.title.len > 0) {
            try form.styles.title.paint(w, form.title);
            try w.writeAll("\n\n");
        }
        if (form.pages.len == 0) {
            try form.viewRange(w, 0, form.fields.len);
        } else switch (form.layout) {
            .pages => {
                const page = form.pageOf(form.focus);
                try form.viewPage(w, page);
            },
            .stack => for (0..form.pages.len) |page| {
                if (page > 0) try w.writeAll("\n\n");
                try form.viewPage(w, page);
            },
            .columns => |n| try form.viewColumns(w, @max(n, 1)),
        }
        if (form.show_help) {
            try w.writeAll("\n\n");
            try form.styles.help.paint(w, form.helpLine());
        }
    }

    fn helpLine(form: *const Form) []const u8 {
        return switch (form.fields[form.focus].kind) {
            .select => "↑/↓ move • / filter • enter next • esc cancel",
            .multi_select => "↑/↓ move • space toggle • enter next • esc cancel",
            .text => "alt+enter new line • enter next • esc cancel",
            .confirm => "←/→ yes or no • enter next • esc cancel",
            .file => "↑/↓ move • enter open • ← parent • esc cancel",
            else => "tab next • shift+tab back • ←/→ choose • enter submit • esc cancel",
        };
    }

    fn viewPage(form: *const Form, w: *Writer, page: usize) Writer.Error!void {
        const p = form.pages[page];
        if (p.title.len > 0) {
            try form.styles.title.paint(w, p.title);
            try w.writeByte('\n');
            if (p.description.len > 0) {
                try form.styles.description.paint(w, p.description);
                try w.writeByte('\n');
            }
            try w.writeByte('\n');
        }
        const range = form.pageRange(page);
        try form.viewRange(w, range.start, range.end);
    }

    fn viewColumns(form: *const Form, w: *Writer, columns: usize) Writer.Error!void {
        // Each page drawn as a block `column_width` wide, the blocks of a row joined side by
        // side, `columns` pages a row (four at most).
        const per_row = @min(columns, 4);
        var page: usize = 0;
        while (page < form.pages.len) {
            if (page > 0) try w.writeAll("\n\n");
            const count = @min(per_row, form.pages.len - page);
            var storage: [4][4096]u8 = undefined;
            var blocks: [4][]const u8 = undefined;
            for (0..count) |i| {
                var raw: [4096]u8 = undefined;
                var block: Writer = .fixed(&raw);
                form.viewPage(&block, page + i) catch {};
                var out: Writer = .fixed(&storage[i]);
                const style: tui.Style = .{
                    .width = form.column_width,
                    .padding = .{ .right = 2 },
                };
                style.render(&out, block.buffered()) catch {};
                blocks[i] = out.buffered();
            }
            try tui.layout.joinHorizontal(w, .start, blocks[0..count]);
            page += count;
        }
    }

    fn viewRange(form: *const Form, w: *Writer, from: usize, to: usize) Writer.Error!void {
        var first = true;
        for (from..to) |i| {
            const field = &form.fields[i];
            if (field.hide) |hide| if (hide(form)) continue;
            if (!first) try w.writeAll("\n\n");
            first = false;
            const focused = i == form.focus;
            const label = if (focused and field.takesFocus())
                form.styles.focused_label
            else
                form.styles.label;
            try label.paint(w, field.label);
            const typed = field.kind == .input or field.kind == .text;
            if (field.required and typed) try label.paint(w, " *");
            if (field.description.len > 0) {
                try w.writeByte('\n');
                try form.styles.description.paint(w, field.description);
            }
            if (field.kind == .note) continue;
            try w.writeByte('\n');
            switch (field.kind) {
                .input => |*input| try input.view(w),
                .text => |*area| try area.view(w),
                .choice => |choice| try form.viewChoice(w, choice),
                .select => |*s| try form.viewSelect(w, s, focused),
                .multi_select => |*m| try form.viewMultiSelect(w, m, focused),
                .confirm => |c| try form.viewConfirm(w, c, focused),
                .file => |picker| if (focused) {
                    try picker.view(w);
                } else if (picker.chosen) |path| {
                    try form.styles.option.paint(w, path);
                },
                .note => unreachable,
            }
            if (focused) if (form.problem) |problem| {
                try w.writeByte('\n');
                try form.styles.@"error".paint(w, problem);
            };
        }
    }

    fn viewChoice(form: *const Form, w: *Writer, choice: Choice) Writer.Error!void {
        for (choice.options, 0..) |option, i| {
            if (i > 0) try w.writeByte(' ');
            if (i == choice.index) {
                try form.styles.chosen.paint(w, "[");
                try form.styles.chosen.paint(w, option);
                try form.styles.chosen.paint(w, "]");
            } else {
                try w.writeByte(' ');
                try form.styles.option.paint(w, option);
                try w.writeByte(' ');
            }
        }
    }

    fn viewSelect(
        form: *const Form,
        w: *Writer,
        s: *const Select,
        focused: bool,
    ) Writer.Error!void {
        if (!focused) return form.styles.chosen.paint(w, s.selected());
        if (s.filtering or s.filter_len > 0) {
            try form.styles.description.paint(w, "/");
            try w.writeAll(s.query());
            if (s.filtering) try (tui.Style{ .reverse = true }).paint(w, " ");
            try w.writeByte('\n');
        }
        var shown: usize = 0;
        var i = s.offset;
        while (i < s.options.len and shown < s.height) : (i += 1) {
            if (!s.visible(i)) continue;
            if (shown > 0) try w.writeByte('\n');
            shown += 1;
            if (i == s.index) {
                try form.styles.cursor.paint(w, "> ");
                try form.styles.chosen.paint(w, s.options[i]);
            } else {
                try w.writeAll("  ");
                try form.styles.option.paint(w, s.options[i]);
            }
        }
    }

    fn viewMultiSelect(
        form: *const Form,
        w: *Writer,
        m: *const MultiSelect,
        focused: bool,
    ) Writer.Error!void {
        if (!focused) {
            var any = false;
            for (m.options, 0..) |option, i| if (m.isChosen(i)) {
                if (any) try w.writeAll(", ");
                any = true;
                try form.styles.chosen.paint(w, option);
            };
            if (!any) try form.styles.description.paint(w, "none");
            return;
        }
        for (m.options[0..@min(m.options.len, 64)], 0..) |option, i| {
            if (i > 0) try w.writeByte('\n');
            if (i == m.cursor) try form.styles.cursor.paint(w, "> ") else try w.writeAll("  ");
            if (m.isChosen(i)) {
                try form.styles.chosen.paint(w, "[•] ");
                try form.styles.chosen.paint(w, option);
            } else {
                try form.styles.option.paint(w, "[ ] ");
                try form.styles.option.paint(w, option);
            }
        }
    }

    fn viewConfirm(form: *const Form, w: *Writer, c: Confirm, focused: bool) Writer.Error!void {
        const on = if (focused) form.styles.button else form.styles.chosen;
        const off = form.styles.blurred_button;
        try (if (c.value) on else off).paint(w, " ");
        try (if (c.value) on else off).paint(w, c.affirmative);
        try (if (c.value) on else off).paint(w, " ");
        try w.writeByte(' ');
        try (if (!c.value) on else off).paint(w, " ");
        try (if (!c.value) on else off).paint(w, c.negative);
        try (if (!c.value) on else off).paint(w, " ");
    }
};

const testing = std.testing;
const Driver = tui.testing.Driver(Form);

/// The default styles without colors, for tests that compare text.
const plain: Form.Styles = .base;

fn noSpaces(text: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, text, ' ') != null) return "no spaces, please";
    return null;
}

fn testFields() [2]Field {
    return .{
        .{
            .label = "Name",
            .kind = .{ .input = .{ .gpa = testing.allocator, .validate = noSpaces } },
            .required = true,
        },
        .{
            .label = "Pin",
            .description = "Four digits",
            .kind = .{ .input = .{ .gpa = testing.allocator, .password = true, .prompt = "" } },
        },
    };
}

fn freeFields(fields: []Field) void {
    for (fields) |*field| field.deinit();
}

test "fill in the fields and submit" {
    var fields = testFields();
    defer freeFields(&fields);
    var d: Driver = try .init(testing.allocator, .{ .fields = &fields, .show_help = false }, .{});
    defer d.deinit();
    try d.expectFrame("Name *\n>  \n\nPin\nFour digits"); // an empty, unfocused field draws nothing
    try d.typeText("ada");
    try d.press("enter");
    try testing.expectEqual(1, d.model().focus);
    try d.typeText("1234");
    try d.expectFrame("Name *\n> ada\n\nPin\nFour digits\n•••• ");
    try d.press("enter");
    try testing.expect(d.done());
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqualStrings("ada", fields[0].kind.input.value());
    try testing.expectEqualStrings("1234", fields[1].kind.input.value());
}

test "an invalid field keeps the focus and says why" {
    var fields = testFields();
    defer freeFields(&fields);
    var d: Driver = try .init(testing.allocator, .{ .fields = &fields, .title = "Sign up" }, .{});
    defer d.deinit();
    try d.press("enter");
    try testing.expectEqual(0, d.model().focus);
    try d.expectFrameContains("This field is required");
    try d.typeText("a b");
    try d.press("tab");
    try testing.expectEqual(1, d.model().focus);
    try d.press("enter"); // submitting finds the bad name
    try testing.expect(!d.done());
    try testing.expectEqual(0, d.model().focus);
    try d.expectFrame("Sign up\n\nName *\n> a b \nno spaces, please\n\nPin\nFour digits\n\n\n" ++
        "tab next • shift+tab back • ←/→ choose • enter submit • esc cancel");
    try d.press("backspace");
    try d.press("backspace");
    try d.press("shift+tab"); // stays on the first field
    try d.press("down");
    try d.press("enter");
    try testing.expect(d.done());
}

test "esc cancels; pastes go to the focused field" {
    var fields = testFields();
    defer freeFields(&fields);
    var d: Driver = try .init(testing.allocator, .{ .fields = &fields }, .{});
    defer d.deinit();
    try d.press("tab");
    try d.paste("42");
    try testing.expectEqualStrings("42", fields[1].kind.input.value());
    try d.press("esc");
    try testing.expectEqual(Status.canceled, d.model().status);
}

test "a choice moves with left and right, and cycles with space" {
    var fields = [_]Field{
        .{ .label = "Plan", .kind = .{ .choice = .{ .options = &.{ "free", "pro", "team" } } } },
        .{ .label = "Name", .kind = .{ .input = .{ .gpa = testing.allocator } } },
    };
    defer for (&fields) |*field| field.deinit();
    var d: Driver = try .init(testing.allocator, .{ .fields = &fields, .show_help = false }, .{});
    defer d.deinit();
    try d.expectFrame("Plan\n[free]  pro   team \n\nName\n> ");
    try d.press("right");
    try d.press("l");
    try d.press("right"); // stays on the last
    try testing.expectEqualStrings("team", fields[0].kind.choice.selected());
    try d.press("space"); // wraps around
    try d.press("left"); // stays on the first
    try d.paste("ignored");
    try d.expectFrame("Plan\n[free]  pro   team \n\nName\n> ");
    try d.press("enter");
    try d.typeText("x");
    try d.press("enter");
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqual(0, fields[0].kind.choice.index);
}

test "selects filter, multi-selects need their minimum, confirms toggle" {
    var fields = [_]Field{
        .{
            .label = "Region",
            .kind = .{ .select = .{ .options = &.{ "eu-west", "us-east", "ap-south" } } },
        },
        .{ .label = "Extras", .kind = .{ .multi_select = .{
            .options = &.{ "ssl", "cdn", "waf" },
            .min = 1,
            .limit = 2,
        } } },
        .{ .label = "Agree?", .kind = .{ .confirm = .{} } },
    };
    var d: Driver = try .init(
        testing.allocator,
        .{ .fields = &fields, .show_help = false, .styles = plain },
        .{},
    );
    defer d.deinit();
    try d.expectFrame("Region\n> eu-west\n  us-east\n  ap-south\n\nExtras\nnone\n\n" ++
        "Agree?\n Yes   No ");
    try d.typeText("/us");
    try d.press("enter"); // ends the filter
    try d.expectFrameContains("> us-east");
    try d.press("enter");
    try testing.expectEqualStrings("us-east", fields[0].kind.select.selected());
    try d.press("enter"); // nothing chosen yet
    try d.expectFrameContains("Choose more");
    try d.press("space");
    try d.press("down");
    try d.press("space");
    try d.press("down");
    try d.press("space"); // the limit is two
    try testing.expectEqual(2, fields[1].kind.multi_select.count());
    try d.press("enter");
    try d.press("y");
    try d.press("enter");
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expect(fields[2].kind.confirm.value);
}

fn proOnly(form: *const Form) bool {
    return form.fields[0].kind.choice.index != 1;
}

test "pages show one at a time; hidden fields are skipped" {
    var fields = [_]Field{
        .{ .label = "Plan", .kind = .{ .choice = .{ .options = &.{ "free", "pro" } } } },
        .{
            .label = "Seats",
            .kind = .{ .input = .{ .gpa = testing.allocator } },
            .hide = proOnly,
            .required = true,
        },
        .{ .label = "About", .description = "That is all.", .kind = .note },
        .{ .label = "Notes", .kind = .{ .text = .{ .gpa = testing.allocator } } },
    };
    defer for (&fields) |*field| field.deinit();
    var d: Driver = try .init(testing.allocator, .{
        .fields = &fields,
        .pages = &.{ .{ .title = "Plan", .count = 2 }, .{ .title = "More", .count = 2 } },
        .show_help = false,
        .styles = plain,
    }, .{});
    defer d.deinit();
    // Free plan: no seats asked.
    try d.expectFrame("Plan\n\nPlan\n[free]  pro ");
    try d.press("enter");
    try testing.expectEqual(3, d.model().focus); // the note is skipped too
    try d.expectFrameContains("More");
    try d.typeText("line one");
    try d.press("alt+enter");
    try d.typeText("two");
    try d.press("shift+tab");
    try d.press("right"); // pro
    try d.press("enter"); // now seats is asked, and required
    try testing.expectEqual(1, d.model().focus);
    try d.press("enter");
    try d.expectFrameContains("This field is required");
    try d.typeText("5");
    try d.press("enter");
    try d.press("enter");
    try testing.expectEqual(Status.submitted, d.model().status);
    try testing.expectEqualStrings("line one\ntwo", fields[3].kind.text.value());
}
