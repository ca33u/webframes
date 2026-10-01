# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's **Report a
vulnerability** button on this repository's Security tab, not in public
issues. Include the Web Frames version (About Web Frames), macOS version and
steps to reproduce. You will get a reply within a week.

## Scope

Most relevant are issues that let a web page, a shared `.webframes` project or
another local process:

- read or write files outside what the user approved,
- make a coding agent receive source or credentials it should not,
- write source without the user pressing Apply,
- talk to the local agent connector or comments MCP inbox.

The design boundaries are described in [Tools/README.md](Tools/README.md#boundaries).

## Supported versions

Only the latest release on [webframes.pro](https://www.webframes.pro) receives
fixes. Updates are delivered through Sparkle.
