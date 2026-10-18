//! `termancy cli docs`: reference documentation for every termancy command. `cli.docs.command`,
//! with termancy's own description and examples.

const cli = @import("cli");

pub const command = command: {
    var docs = cli.docs.command;
    docs.description =
        \\Print the documentation of the whole command tree to standard output: Markdown, one
        \\man page, one HTML page, or JSON (see docs/machine-output.md). With --dir and
        \\--format man, write one page per command instead (termancy.1, termancy-cfg.1,
        \\termancy-cfg-get.1, ...), linked to each other under SEE ALSO.
    ;
    docs.examples =
        \\termancy cli docs > TERMANCY.md
        \\termancy cli docs --format man > termancy.1
        \\termancy cli docs --format man --dir man/man1
        \\termancy cli docs --format html > termancy.html
        \\termancy cli docs --format html --stylesheet site.css > commands.html
    ;
    break :command docs;
};
