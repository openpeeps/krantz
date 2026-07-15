<p align="center">
  Banksy ~ a fast ZSH alternative written in Nim<br>
  Compiled &bullet; Command Policy &bullet;
</p>

<p align="center">
  <code>nimble install banksy</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/banksy">API reference</a><br>
  <img src="https://github.com/openpeeps/banksy/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/banksy/workflows/docs/badge.svg" alt="Github Actions">
</p>

## 😍 Key Features

- Interactive REPL with line editing and tab completion
- POSIX-style expansion: tilde, env vars, command substitution, glob
- Variable assignment (`FOO=bar`) with `export` / `unset`
- Pipelines, redirections, background processes, conditional operators
- Policy engine to deny dangerous commands
- SQLite-backed persistent history
- Styled configurable prompt (user, host, git, cwd)
- OSC 7 terminal cwd tracking
- YAML configuration (`~/.banksy/config.yaml`)
- Builtins: `cd`, `exit`, `history`, `trash`, `export`, `unset`

## Line Editing

Emacs keybindings, history search (Ctrl-R), kill/yank ring, incremental search, three-phase file path completion (case-insensitive on macOS).

## Expansion

Tilde (`~`, `~user`), environment variables (`$VAR`, `${VAR}`, `${VAR:-=+?word}`), command substitution (`$(cmd)`, `` `cmd` ``), glob (`*`, `?`, `[...]`). Applied in POSIX order.

## Terminal Integration

OSC 7 cwd emission for same-directory new tabs. Graceful SIGHUP/SIGTERM shutdown. SA_RESTART for SIGWINCH. Unknown CSI sequences consumed. Terminal modes reset at startup.

## Examples
...

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/banksy/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/banksy/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/banksy/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
LGPLv3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
