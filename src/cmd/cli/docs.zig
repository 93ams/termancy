//! `snek cli docs`: reference documentation for every snek command. `cli.docs.command`,
//! with snek's own description and examples.

const cli = @import("cli");

pub const command = command: {
    var docs = cli.docs.command;
    docs.description =
        \\Print the documentation of the whole command tree to standard output: Markdown, one
        \\man page, one HTML page, or JSON (see docs/machine-output.md). With --dir and
        \\--format man, write one page per command instead (snek.1, snek-cfg.1,
        \\snek-cfg-get.1, ...), linked to each other under SEE ALSO.
    ;
    docs.examples =
        \\snek cli docs > SNEK.md
        \\snek cli docs --format man > snek.1
        \\snek cli docs --format man --dir man/man1
        \\snek cli docs --format html > snek.html
        \\snek cli docs --format html --stylesheet site.css > commands.html
    ;
    break :command docs;
};
