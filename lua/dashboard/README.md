# Status Dashboard

A single floating window in Neovim that surfaces my GitHub PRs, GitHub
notifications, Jira tickets, and today's notes/todos — with one-keystroke
actions for opening, checking out, diffing, browsing review threads, asking
Claude, and managing the daily notes file.

## Features

- **GitHub**: my open PRs and PRs awaiting my review, sorted by repo. Per-row
  badges for CI status, review state (`✓` for 2+ approvals, `◐` for 1, `○` for
  none yet, `✗` for changes requested), stale-age coloring, draft tag, and
  unresolved review-thread count.
- **Notifications inbox** from `gh api notifications`. Mark a row as read
  in-place with `x`.
- **Jira** active tickets grouped into per-status sections (`In Progress`,
  `Peer Review`, `Needs QA`, `In QA`, `Passed QA`, `Refinement`, plus any
  `Blocked` / `On Hold` if configured). Each ticket shows QA assignee and
  days-in-status. PRs that mention a ticket key auto-attach as sub-lines.
- **Today's notes and todos** — reads `~/notes/YYYY-MM-DD.txt`. `n` appends a
  free-form note, `T` appends a `- [ ]` todo, `x` toggles a todo's checkbox in
  the file. The file is auto-created on first append. View is sorted: open
  todos first (yellow), plain notes in the middle, completed todos at the
  bottom (muted).
- **Cross-section filter** — `f` narrows every section at once by ticket key,
  repo, or any substring (notes included).
- **Per-row actions**: open in browser, yank URL, checkout PR in a new tmux
  pane, view diff in a floating window, view all unresolved review threads,
  mark notification as read.
- **Claude integration** via the local `claude` CLI (no API key needed) for
  one-keystroke summary, understand, risks, next-step, and code-review prompts.

## Prerequisites

- **Neovim 0.10+** (uses `vim.system`, `vim.uv`, `vim.base64`, `vim.json` with
  `luanil`).
- **`gh` CLI**, authenticated: `gh auth login`.
- **`claude` CLI** for the `s` / `?` prompt actions. Without it, those keys
  surface a "claude CLI not found" notify and do nothing.
- **`JIRA_EMAIL` and `JIRA_API_TOKEN`** env vars for the Jira section.
- **tmux** (optional) for the `c` checkout action. Without it, `c` notifies
  "Not in a tmux session" and no-ops.

## Install

1. Copy two paths from this repo into your own Neovim config:
   - `lua/dashboard/` — the whole module, unchanged.
   - `lua/api/dashboard.lua` — the wiring file. Edit this to set your own
     `repo_paths`, `jira_status_order`, and Jira base URL.
2. Make sure your config requires the wiring file at startup. In this repo it
   loads via `lua/api/init.lua`:

   ```lua
   require 'api.dashboard'
   ```

   If your config doesn't have an `api/` folder, you can call
   `require('dashboard').setup{ ... }` directly from your `init.lua` instead
   of using a separate wiring file.

## Configuration

Open `lua/api/dashboard.lua` and adjust:

```lua
require('dashboard').setup {
  -- Map "org/repo" -> local path on disk. Used by `c` (checkout PR in tmux).
  repo_paths = {
    ['myorg/some-service']   = '~/projects/some-service',
    ['myorg/other-repo']     = '~/projects/other-repo',
  },

  -- Order in which Jira status sections render. Sections with zero tickets
  -- are hidden. Anything not listed here falls into a final "Other" section.
  jira_status_order = {
    'Blocked',
    'In Progress',
    'Peer Review',
    'Needs QA',
    'In QA',
    'Passed QA',
  },

  -- Jira base URL. Defaults to vitalsource.atlassian.net; override here or
  -- via the JIRA_BASE_URL env var.
  jira = { base_url = 'https://your-company.atlassian.net' },

  -- Claude CLI model (optional). Pass any value the `claude --model` flag
  -- accepts. Unset means use whatever your `claude` default is.
  claude = { model = 'haiku-4-5' },

  -- Seconds before the dashboard auto-refreshes on FocusGained. Default 60.
  refresh_after = 60,

  -- Daily notes file. Defaults shown. Filename is os.date() format.
  notes = {
    notes_dir = '~/notes',
    filename_format = '%Y-%m-%d.txt',
  },
}
```

## Keymaps

### Global

| Key | Action |
| --- | --- |
| `<leader>od` | Open the dashboard (or refocus if already open) |
| `<leader>or` | Refocus the most recently opened result window (Claude / diff / threads) |

### Inside the dashboard

| Key | Action |
| --- | --- |
| `<CR>` | Open the row's URL in the browser |
| `y` | Yank the row's URL to the clipboard |
| `f` | Filter every section by a substring (ticket key, repo, text) |
| `r` | Refresh now |
| `q` / `<Esc>` | Close the dashboard |

PR rows additionally:

| Key | Action |
| --- | --- |
| `c` | `gh pr checkout <num>` in a new tmux pane in the configured repo dir |
| `D` | Show the PR diff in a floating window (markdown filetype, scrollable) |
| `t` | Show all unresolved review threads with diff hunks and threaded comments |
| `s` | Ask Claude for a one-keystroke summary |
| `?` | Pick from: summary, understand, risks, next-step, code-review |

Notification rows additionally:

| Key | Action |
| --- | --- |
| `x` | Mark the notification as read (removes the row locally) |

Notes section additionally:

| Key | Action |
| --- | --- |
| `n` | Append a free-form note to today's file (auto-prepends `- `) |
| `T` | Append a todo to today's file (auto-prepends `- [ ] `) |
| `x` | Toggle the checkbox on the cursor row (`- [ ]` ↔ `- [x]`) |
| `<CR>` | Close dashboard and open today's notes file for editing |

Jira rows: `s` and `?` work on tickets too.

### Inside the result window (Claude / diff / threads)

| Key | Action |
| --- | --- |
| `q` / `<Esc>` | Close |
| `1` … `5` | Re-prompt against the cached context with the next prompt (Claude window only) |

## Caveats

- The GitHub search query in `lua/dashboard/github.lua` excludes the
  `VirdocsSoftware` org via a `-org:VirdocsSoftware` qualifier. Adjust to your
  own org filter (or remove it entirely).
- Filtering is plain case-insensitive substring, so `VST-100` also matches
  `VST-1000`. Type a few more chars to disambiguate.
- "Days in status" uses Jira's `statuscategorychangedate`, which only updates
  when the status *category* changes (To Do / In Progress / Done). A
  `Needs QA → In QA` move stays in the In Progress category and won't bump
  the value. Good enough for spotting stuck tickets without N+1 calls per
  refresh.
- The unresolved-thread count comes from GraphQL `reviewThreads` and includes
  threads marked outdated. The `t` action surfaces them with an `[outdated]`
  tag so context isn't surprising.
- Re-prompts in the Claude result window are instant because the fetched
  context is cached per dashboard session. The cache clears when you close
  the dashboard.
- The notes section sorts entries for display (open todos → plain notes →
  completed todos), but the underlying file stays append-only chronological,
  so it remains grep-friendly and readable elsewhere.
