import std/[os, posix, strutils]

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
  parts.add(foreground(tilde(getCwd()), ckCyan))
  if branch.len > 0:
    parts[^1] = parts[^1] & " " & foreground("(" & branch & ")", ckYellow)
  let arrow = if lastExitCode == 0: foreground("›", ckMagenta) else: foreground("›", ckRed)
  result = parts.join(" ") & " " & arrow & " "
