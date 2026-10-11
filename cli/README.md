# bupsy

The command line for [bupsy.pages.dev](https://bupsy.pages.dev): what Bupsy is, its pages as Markdown, the waitlist, and its MCP server. Bupsy is a native Mac app for a team of AI bots that run on your own Claude Code or Codex subscription.

```sh
npx bupsy about                 # what Bupsy is, and when to use it
npx bupsy page developers       # any page as Markdown
npx bupsy join you@example.com  # join the waitlist
npx bupsy mcp                   # add Bupsy's MCP server to your agent
npx bupsy openapi               # the API's OpenAPI 3.1 document
```

`--json` prints the API's JSON. Exit codes: 0 done, 1 the API said no (with what to do next on stderr), 2 wrong usage. No dependencies; Node 18 or later.

Made by Xocket Labs Inc. Not affiliated with Anthropic or OpenAI.
