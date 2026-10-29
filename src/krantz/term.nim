# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[algorithm, os, posix, sets, strutils, terminal, termios]
import openparser/fuzzy
import ./private/noise
import ./private/noise/posixio as noiseio

const TIOCGWINSZ = 0x40087468

type Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
  ws_row: cushort
  ws_col: cushort
  ws_xpixel: cushort
  ws_ypixel: cushort

proc ioctl(fd: cint; req: culong; arg: pointer): cint {.importc, header: "<sys/ioctl.h>".}

proc terminalWidth*(): int =
  var w: Winsize
  if ioctl(0, TIOCGWINSZ, addr(w)) == 0 and w.ws_col > 0.cushort:
    result = int(w.ws_col)
  else:
    result = 80

proc visibleLength*(s: string): int =
  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      inc i
      if i < s.len and s[i] == '[':
        inc i
        while i < s.len and s[i] notin {'A'..'Z', 'a'..'z'}:
          inc i
        if i < s.len: inc i
      elif i < s.len:
        inc i
    else:
      inc result
      inc i
      if i > 0 and s[i-1].ord >= 0xC2:
        while i < s.len and s[i].ord >= 0x80 and s[i].ord <= 0xBF:
          inc i

proc isTerminal*(fd: cint): bool =
  posix.isatty(fd) != 0

var gNoise*: Noise

const X_OK = 1.cint

proc hiddenFor(prefix: string, name: string): bool =
  name.len > 0 and name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')

proc cmpShortestFirst*(a, b: string): int =
  ## Shortest candidate wins; ties break alphabetically (case-insensitive,
  ## then case-sensitive for full determinism).
  if a.len != b.len: return cmp(a.len, b.len)
  result = cmpIgnoreCase(a, b)
  if result == 0: result = cmp(a, b)

proc cmpCompletion(a, b: tuple[path: string, isDir: bool]): int =
  ## Sort helper for dir-aware candidate lists (slashless paths).
  cmpShortestFirst(a.path, b.path)

proc splitCompletionKeep(text: string): tuple[keep, core: string] =
  ## Splits a completion word into a literal prefix (`keep`, re-attached to
  ## every candidate) and the part actually matched against the filesystem
  ## (`core`). This keeps `--opt=value` suffixes and redirection targets
  ## (`>`, `>>`, `<`, `&>`, `2>`) completable now that `=<>...` are word
  ## characters (zsh WORDCHARS): only `core` drives prefix/fuzzy matching
  ## and directory walks, while candidates are emitted as `keep & match`.
  var rest = text
  var keep = ""
  let rl = redirPrefixLen(text)
  if rl > 0:
    keep = text[0 ..< rl]
    rest = if rl < text.len: text[rl .. ^1] else: ""
  if rest.len == 0:
    return (keep, rest)
  let eq = rest.rfind('=')
  if eq >= 0:
    keep = keep & rest[0 .. eq]
    rest = rest[eq + 1 .. ^1]
  (keep, rest)

proc addCandidates(self: var Noise, text: string, dirsOnly: bool): int =
  # Only `core` is matched against the filesystem; `keep` (redirection
  # operators, `name=` prefixes) is prepended back onto every candidate.
  let (keep, core) = splitCompletionKeep(text)
  let expanded = core.expandTilde()

  # Phase 2: core ends with "/" → list directory contents.
  # Children complete without a trailing slash; TAB cycles them at
  # this level, typing "/" descends further.
  if core.endsWith("/"):
    var entries: seq[tuple[path: string, isDir: bool]]
    try:
      for kind, path in walkDir(expanded):
        let entry = path.extractFilename()
        if hiddenFor("", entry): continue
        if kind in {pcDir, pcLinkToDir}:
          entries.add((keep & (core / entry), true))
        elif not dirsOnly:
          entries.add((keep & (core / entry), false))
    except OSError:
      discard
    sort(entries, cmpCompletion)
    for e in entries:
      self.addCompletion(e.path, e.isDir)
    return entries.len

  # Phase 1: core matches an exact directory → keep it (no slash, so TAB
  # stays at this level) and offer same-level siblings after it.
  if dirExists(expanded):
    var count = 0
    self.addCompletion(text, true)
    inc count
    let parent = core.parentDir()
    let basename = core.extractFilename()
    let absParent = if parent.len > 0: parent.expandTilde() else: "."
    var siblings: seq[tuple[path: string, isDir: bool]]
    try:
      for kind, path in walkDir(absParent):
        let name = path.extractFilename()
        if hiddenFor(basename, name): continue
        if name.toLowerAscii() == basename.toLowerAscii(): continue
        if name.len >= basename.len and name.toLowerAscii()[0..<basename.len] == basename.toLowerAscii():
          let completion = keep & (if parent.len > 0: parent / name else: name)
          if kind in {pcDir, pcLinkToDir}:
            siblings.add((completion, true))
          elif not dirsOnly:
            siblings.add((completion, false))
    except OSError:
      discard
    if siblings.len > 0:
      sort(siblings, cmpCompletion)
      for s in siblings:
        self.addCompletion(s.path, s.isDir)
        inc count
    return count

  # Phase 3: prefix match (dirs complete without trailing slash)
  var dir = "."
  var prefix = core
  if core.contains("/") or core.contains("~"):
    dir = core.parentDir()
    prefix = core.extractFilename()

  var candidates: seq[tuple[path: string, isDir: bool]]
  let absDir = dir.expandTilde()
  try:
    for kind, path in walkDir(absDir):
      let name = path.extractFilename()
      if hiddenFor(prefix, name): continue
      if name.len >= prefix.len and name.toLowerAscii()[0..<prefix.len] == prefix.toLowerAscii():
        let completion = keep & (if dir != ".": dir / name else: name)
        if kind in {pcDir, pcLinkToDir}:
          candidates.add((completion, true))
        elif not dirsOnly:
          candidates.add((completion, false))
  except OSError:
    discard
  if candidates.len > 0:
    sort(candidates, cmpCompletion)
    for c in candidates:
      self.addCompletion(c.path, c.isDir)
    result = candidates.len
  elif prefix.len > 0:
    # Phase 4: fuzzy match fallback (openparser/fuzzy, score order kept)
    var haystack: seq[string]
    try:
      for kind, path in walkDir(absDir):
        let name = path.extractFilename()
        if hiddenFor("", name): continue
        if dirsOnly and kind notin {pcDir, pcLinkToDir}: continue
        haystack.add(name)
    except OSError:
      discard
    if haystack.len > 0:
      let matches = fuzzySearch(prefix, haystack, FuzzyOptions(limit: 10))
      for m in matches:
        let name = m.text
        let completion = keep & (if dir != ".": dir / name else: name)
        if dirExists(absDir / name):
          self.addCompletion(completion, true)
        elif not dirsOnly:
          self.addCompletion(completion)
      result = matches.len

const shellBuiltins = [
  "alias", "bg", "cd", "clear", "echo", "env", "exit", "export", "fg",
  "history", "jobs", "kill", "logout", "pwd", "source", "unset", "wait"
]

var gCommandCache = ""
var gCommandNames: seq[string]

proc buildCommandCache() =
  let path = getEnv("PATH")
  if gCommandCache == path: return
  gCommandCache = path
  gCommandNames.setLen(0)
  var seen = initHashSet[string]()
  for dir in path.split(PathSep):
    if dir.len == 0: continue
    try:
      for kind, file in walkDir(dir):
        if kind notin {pcFile, pcLinkToFile}: continue
        let name = file.extractFilename()
        if name.len == 0 or name[0] == '.': continue
        if posix.access(file.cstring, X_OK) != 0: continue
        if seen.containsOrIncl(name): continue
        gCommandNames.add name
    except OSError:
      discard

proc commandCandidates(prefix: string): seq[string] =
  buildCommandCache()
  let lower = prefix.toLowerAscii()
  for b in shellBuiltins:
    if b.len >= prefix.len and b.toLowerAscii()[0..<prefix.len] == lower:
      result.add b
  for name in gCommandNames:
    if name.len >= prefix.len and name.toLowerAscii()[0..<prefix.len] == lower:
      if result.find(name) < 0:
        result.add name
  sort(result, cmpShortestFirst)

proc unescapeWord(word: string): string =
  var i = 0
  while i < word.len:
    if word[i] == '\\' and i + 1 < word.len:
      inc i
      result.add(word[i])
    else:
      result.add(word[i])
    inc i

proc completeCallback(self: var Noise, text: string): int =
  let fullLine = self.getLine()
  let words = fullLine.splitWhitespace()
  let firstWord = if words.len > 0: words[0] else: ""
  let isFirstWord = fullLine.find(' ') < 0
  let cdArg = firstWord == "cd" and not isFirstWord
  let word = text.unescapeWord()

  if isFirstWord:
    if word.len == 0: return 0
    if word.contains("/"):
      result = self.addCandidates(word, dirsOnly = false)
    else:
      let cmds = commandCandidates(word)
      for name in cmds:
        self.addCompletion(name)
      result = cmds.len
  else:
    result = self.addCandidates(word, dirsOnly = cdArg)

proc resetTerminalModes*() =
  # NOTE: do not disable mouse tracking (1000/1002/1003/1006) here — that mode
  # is terminal-global and disabling it breaks apps krantz runs inside of
  # (e.g. an embedded terminal in a TUI). Leftover mouse events are ignored
  # by the input layer instead.
  stdout.write("\e[?1004l\e[?2004l\e[?25h\e[?7h")
  stdout.flushFile()

proc drainStdin*() =
  var buf: array[256, char]
  var s: TFdSet
  var tv: Timeval
  tv.tv_sec = 0.Time; tv.tv_usec = 0
  let fd = getFileHandle(stdin)

  var oldTermios, rawTermios: Termios
  var drained = false
  if fd.tcGetAttr(oldTermios.addr) != -1:
    rawTermios = oldTermios
    rawTermios.c_iflag = rawTermios.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
    rawTermios.c_lflag = rawTermios.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
    rawTermios.c_cc[VMIN] = 1.cuchar
    rawTermios.c_cc[VTIME] = 0.cuchar
    discard fd.tcSetAttr(TCSADRAIN, rawTermios.addr)
    drained = true

  while true:
    s.FD_ZERO; fd.FD_SET(s)
    if posix.select(1, s.addr, nil, nil, tv.addr) <= 0:
      break
    discard posix.read(fd, buf[0].addr, 256)

  if drained:
    discard fd.tcSetAttr(TCSADRAIN, oldTermios.addr)

proc prepareChildTerminal*() =
  drainStdin()

proc initTerminal*() =
  stdout.write("\n")
  stdout.flushFile()
  gNoise = Noise.init()
  gNoise.setCompletionHook(completeCallback)
  gNoise.historySetMaxLen(1000)
  noiseio.installShutdownHandler()
  resetTerminalModes()

proc readLineInput*(prompt: Styler): tuple[success: bool, line: string] =
  gNoise.setPrompt(prompt)
  if gNoise.readLine():
    result = (true, gNoise.getLine())
  else:
    result = (false, "")

proc historySaveToFile*(path: string) =
  discard gNoise.historySave(path)

proc historyLoadFromFile*(path: string) =
  discard gNoise.historyLoad(path)

proc isShuttingDown*(): bool =
  noiseio.gShuttingDown

proc emitCurrentDir*(dir: string) =
  var encoded = ""
  for c in dir:
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '/', '-', '.', '_', '~': encoded.add(c)
    else: encoded.add("%" & toHex(ord(c), 2))
  stdout.write("\e]7;file://localhost" & encoded & "\e\\")
  stdout.flushFile()
