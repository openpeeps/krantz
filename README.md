<p align="center">
  <img src="https://raw.githubusercontent.com/georgelemon/krantz/main/.github/krantz.svg" alt="krantz" width="240px" height="auto"><br>
  Krantz ~ a fast ZSH alternative written in Nim<br>
  Compiled &bullet; YAML Command Policy &bullet; History
</p>

<p align="center">
  <code>nimble install krantz</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/krantz">API reference</a><br>
  <img src="https://github.com/openpeeps/krantz/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/krantz/workflows/docs/badge.svg" alt="Github Actions">
</p>

> [!NOTE]
> Krantz is still a work in progress, but already pretty usable as a daily driver

## 😍 Key Features

- Interactive REPL with line editing and tab completion
- POSIX-style expansion: tilde, env vars, command substitution, glob (via delegated shell)
- Variable assignment (`FOO=bar`) with `export` / `unset`
- Pipelines, redirections, background processes, conditional operators
- Policy engine to deny dangerous commands
- Persistent storage for history
- Styled configurable prompt (user, host, git, cwd)
- OSC 7 terminal cwd tracking
- YAML configuration (`~/.krantz/config.yaml`)
- Builtins: `cd`, `exit`, `history`, `trash`, `export`, `unset`

## Install
You need nim. Once built add it to your `/etc/shells`, then in Terminal app add the absolute path

## Line Editing

Emacs keybindings, history search (Ctrl-R), kill/yank ring, incremental search, three-phase file path completion (case-insensitive on macOS).

## Expansion

Tilde (`~`, `~user`) expansion is handled natively. All `$`-based expansion (environment variables, `${:-=+?}` operators, command substitution, arithmetic) and backtick substitution is delegated to `/bin/sh` via fork/exec, ensuring full shell compatibility. Globbing (`*`, `?`, `[...]`) is handled natively. Expansion order follows POSIX semantics.

## Terminal Integration

OSC 7 cwd emission for same-directory new tabs. Graceful SIGHUP/SIGTERM shutdown. SA_RESTART for SIGWINCH. Unknown CSI sequences consumed. Terminal modes reset at startup.

Child processes receive proper process-group membership (`setpgid`) and terminal foreground ownership (`tcsetpgrp`) via blocked `SIGTTOU`/`SIGTTIN`, matching the POSIX job-control model. After a foreground child exits, the terminal is reclaimed and input-affecting modes (mouse tracking, focus events, bracketed paste) are reset without disturbing the child's visible output. Stale stdin is drained before each child runs.

## Examples
...

### Krantz Config

Configuration lives at `~/.krantz/config.yaml`. First-time initialization automatically creates the config file under `~/.krantz/` with a default policy that denies dangerous commands:

```yaml
policy:
  deny:
    - rm

history:
  maxSize: 1000

prompt:
  user: false       # show username in the cmd line
  host: false       # show hostname in the cmd line
  git: true         # enable git branch status
  cwdShort: false  
```

### 🗺 Roadmap

Ideas and planned features to evolve krantz into a full-featured ZSH/bash alternative:

- **Job control** ~ `fg`, `bg`, `jobs`, `Ctrl-Z` suspend/resume
- **Completion system** ~ command-specific completions (git branches, npm packages, SSH hosts, Makefile targets), programmable completion akin to `zsh-completions`
- **Syntax highlighting** ~ real-time highlighting of the input line
- **Autosuggestions** ~ grayed-out history-based suggestions as you type (fish/zsh-autosuggestions style)
- **Vim mode** ~ vi keybindings with visual/insert/normal modes
- **Directory stack** ~ `pushd`/`popd`/`dirs` for fast directory hopping
- **Directory jumper** ~ fuzzy directory navigation via `z`/`zoxide`-style frecency
- **Plugin system** ~ load external modules without recompiling the shell
- **Prompt themes** ~ user-switchable prompt presets with colors, segments, and status indicators
- **Alias system** ~ global and suffix aliases, alias expansion hints
- **Keybinding config** ~ user-definable keybindings via YAML
- **History substring search** ~ type part of a command, press up-arrow to match (like `history-substring-search`)
- **Fuzzy matching** ~ integrate `fzf` for `Ctrl-T` file search, `Ctrl-R` history reverse search
- **Built-in help** ~ `help` builtin with support for builtins, config, and keybindings
- **Session persistence** ~ save/restore REPL state (cwd, variables, history position)
- **LLM integration** ~ inline AI suggestions, natural-language-to-command translation
- **Config hot-reload** ~ apply config changes without restarting the shell
- **Mouse support** ~ click-to-position cursor in the REPL input line
- **Shell scripting** ~ execute `.krantzrc` and script files with krantz builtins

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/krantz/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/krantz/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
GPLv3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
