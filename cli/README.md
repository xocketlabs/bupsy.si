# bupsy

The command line for [bupsy.si](https://bupsy.si): what Bupsy is, its pages as Markdown, the download, and its MCP server. Bupsy is a native Mac app for a team of AI bots that run on your own Claude Code or Codex subscription.

```sh
npx bupsy about                               # what Bupsy is, and when to use it
npx bupsy page developers                     # any page as Markdown
npx bupsy download you@example.com            # get Bupsy, free, for your email address
npx bupsy download you@example.com --updates  # and one email a month about what's new
npx bupsy mcp                                 # add Bupsy's MCP server to your agent
npx bupsy openapi                             # the API's OpenAPI 3.1 document
```

`download` prints the address of the newest Bupsy.dmg (macOS 14 or later, Apple silicon and Intel). Open it and drag Bupsy into Applications. Builds may not be Apple-signed yet, so the first time macOS may refuse to open it: open System Settings, Privacy & Security, and click Open Anyway. Without `--updates` Bupsy sends you no email at all.

`join` still works and adds your address to the older "keep me posted" list, without a download.

`--json` prints the API's JSON. Exit codes: 0 done, 1 the API said no (with what to do next on stderr), 2 wrong usage. No dependencies; Node 18 or later.

Made by Xocket Labs Inc. Not affiliated with Anthropic or OpenAI.
