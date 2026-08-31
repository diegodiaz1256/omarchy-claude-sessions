# Omarchy Claude Sessions

Browse every past [Claude Code](https://claude.com/claude-code) session across all your projects and resume one in a terminal, from an Omarchy panel.

Claude's own `claude --resume` picker only lists sessions belonging to the directory it starts in. This panel gathers sessions from every project, shows the folder each one belongs to, and resumes by session id — so continuing yesterday's work in another repo is one keystroke instead of a `cd` followed by a second pick.

## Features

- Every session from every project, most recent first
- Readable titles — uses the `ai-title` Claude generates per session, falling back to the first message you typed
- Type to filter across titles, your original message, and folder paths
- `↑`/`↓` to select, `Enter` to resume, `Esc` to close
- Themed with the active Omarchy theme

## Install

```bash
omarchy plugin add https://github.com/diegodiaz1256/omarchy-claude-sessions --enable
```

Or manually:

```bash
git clone https://github.com/diegodiaz1256/omarchy-claude-sessions \
  ~/.config/omarchy/plugins/diegodiaz1256.claude-sessions
omarchy plugin enable diegodiaz1256.claude-sessions
```

## Usage

Summon the panel:

```bash
omarchy-shell shell summon diegodiaz1256.claude-sessions
```

### Add it to the Omarchy menu

The menu reads `~/.config/omarchy/extensions/omarchy-menu.jsonc`. Add:

```jsonc
"claude": {"icon":"󰛄","label":"Claude","aliases":["ai","claude-code"]},
"claude.resume": {"icon":"󰑖","label":"Resume Session","aliases":["resume"],"action":"omarchy-shell shell summon diegodiaz1256.claude-sessions","when":"command -v claude"},
```

It then appears under **Super → Claude → Resume Session**.

### Bind it to a key

In `~/.config/hypr/bindings.conf`:

```
bind = SUPER, C, exec, omarchy-shell shell summon diegodiaz1256.claude-sessions
```

## How it works

`bin/claude-sessions-list` reads the transcripts under `~/.claude/projects/` and emits JSON. Transcripts reach tens of megabytes, so it reads only the head of each file (for the first typed message and the recorded `cwd`) and the tail (for `ai-title`, which Claude appends as a session grows) rather than parsing them whole — about 45 ms for 13 sessions.

Sessions are resumed by id rather than by folder, so the right conversation is restored even when several share a directory.

The project folder comes from the `cwd` recorded inside the session itself. Claude encodes project paths by replacing `/` with `-`, which is lossy — a folder whose own name contains `-` is indistinguishable from a path separator — so the recorded value is preferred and the encoded directory name is only decoded as a fallback.

## Requirements

- Omarchy with `omarchy-shell`
- `claude` on `PATH`
- `python3` (the panel says so plainly if it is missing)

## License

MIT
