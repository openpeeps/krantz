# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, posix, strutils]
import ./private/noise

import ./types

proc foreground*(s: string, color: ColorKind): string =
  if color == ckNone: return s
  let c = "\x1b[" & $(ord(color) + 30) & "m"
  result = c & s & "\x1b[0m"

proc bold*(s: string): string =
  "\x1b[1m" & s & "\x1b[0m"

proc tilde*(path: string): string =
  let home = getHomeDir()
  if path.startsWith(home):
    result = "~/" & path.split(home)[1]
  else:
    result = path

proc user*(): string =
  result = $getpwuid(getuid()).pw_name

proc host*(): string =
  const size = 256
  result = newString(size)
  discard gethostname(cstring(result), size)
  let nullPos = result.find('\0')
  if nullPos >= 0:
    result.setLen(nullPos)

proc getCwd*(): string =
  result = try:
    getCurrentDir()
  except OSError:
    "[not found]"

proc getGitBranch*(): string =
  var dir = getCurrentDir()
  while true:
    if dirExists(dir / ".git"):
      let headPath = dir / ".git" / "HEAD"
      if fileExists(headPath):
        let head = readFile(headPath).strip()
        if head.startsWith("ref: refs/heads/"):
          return head[16..^1]
        elif head.len > 0:
          return head[0..<7]
      return ""
    let parent = dir.parentDir()
    if parent.len == 0 or parent == dir: break
    dir = parent
  return ""

proc makePrompt*(lastExitCode: int, pc: PromptConfig, branch: string): string =
  var parts: seq[string]
  if pc.user:
    parts.add(foreground(user(), ckGreen))
  if pc.host:
    if parts.len > 0:
      parts[^1] = parts[^1] & "@" & foreground(host(), ckBlue)
    else:
      parts.add(foreground(host(), ckBlue))
  let cwd = getCwd()
  parts.add(foreground(if pc.cwdShort: cwd.splitPath().tail else: tilde(cwd), ckCyan))
  if branch.len > 0:
    parts[^1] = parts[^1] & " " & foreground("git:(" & branch & ")", ckYellow)
  let arrow = if lastExitCode == 0: foreground("›", ckMagenta) else: foreground("›", ckRed)
  result = parts.join(" ") & " " & arrow & " "

proc colorToFg(c: ColorKind): ForegroundColor =
  ForegroundColor(ord(c) + 30)

proc makePromptStyler*(lastExitCode: int, pc: PromptConfig, branch: string): Styler =
  result = newStyler()
  if pc.user:
    result.addCmd(colorToFg(ckGreen))
    result.addCmd(user())
    result.addCmd(resetStyle)
  if pc.host:
    if pc.user:
      result.addCmd("@")
    result.addCmd(colorToFg(ckBlue))
    result.addCmd(host())
    result.addCmd(resetStyle)
  let cwd = getCwd()
  result.addCmd(colorToFg(ckCyan))
  result.addCmd(if pc.cwdShort: cwd.splitPath().tail else: tilde(cwd))
  result.addCmd(resetStyle)
  if branch.len > 0:
    result.addCmd(" ")
    result.addCmd(colorToFg(ckYellow))
    result.addCmd("git:(" & branch & ")")
    result.addCmd(resetStyle)
  result.addCmd(" ")
  result.addCmd(colorToFg(if lastExitCode == 0: ckMagenta else: ckRed))
  result.addCmd("›")
  result.addCmd(resetStyle)
  result.addCmd(" ")
