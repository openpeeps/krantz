# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[algorithm, os, posix, strutils, terminal, termios]
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

proc completeCallback(self: var Noise, text: string): int =
  if text.len == 0: return 0

  let expanded = text.expandTilde()

  # Phase 2: text ends with "/" → list directory contents
  if text.endsWith("/"):
    var count = 0
    try:
      for kind, path in walkDir(expanded):
        let entry = path.extractFilename()
        if kind in {pcDir, pcLinkToDir}:
          self.addCompletion(text / entry & "/")
        else:
          self.addCompletion(text / entry)
        inc count
    except OSError:
      discard
    return count

  # Phase 1: text matches an exact directory → add / and siblings
  if dirExists(expanded):
    var count = 1
    self.addCompletion(text & "/")
    let parent = text.parentDir()
    let basename = text.extractFilename()
    let absParent = if parent.len > 0: parent.expandTilde() else: "."
    try:
      for kind, path in walkDir(absParent):
        let name = path.extractFilename()
        if name.toLowerAscii() == basename.toLowerAscii(): continue
        if name.len >= basename.len and name.toLowerAscii()[0..<basename.len] == basename.toLowerAscii():
          let completion = if parent.len > 0: parent / name else: name
          if kind in {pcDir, pcLinkToDir}:
            self.addCompletion(completion & "/")
          else:
            self.addCompletion(completion)
          inc count
    except OSError:
      discard
    return count

  # Phase 3: prefix match
  var dir = "."
  var prefix = text
  if text.contains("/") or text.contains("~"):
    dir = text.parentDir()
    prefix = text.extractFilename()

  var candidates: seq[string]
  let absDir = dir.expandTilde()
  try:
    for kind, path in walkDir(absDir):
      let name = path.extractFilename()
      if name.len >= prefix.len and name.toLowerAscii()[0..<prefix.len] == prefix.toLowerAscii():
        let completion = if dir != ".": dir / name else: name
        if kind in {pcDir, pcLinkToDir}:
          candidates.add(completion & "/")
        else:
          candidates.add(completion)
  except OSError:
    discard
  if candidates.len > 0:
    sort(candidates, cmpIgnoreCase)
    for c in candidates:
      self.addCompletion(c)
  result = candidates.len

proc resetTerminalModes*() =
  stdout.write("\e[?1000l\e[?1002l\e[?1003l\e[?1006l")
  stdout.write("\e[?1004l\e[?2004l\e[?25h\e[?7h")
  stdout.flushFile()

proc drainStdin*() =
  var buf: array[256, char]
  var s: TFdSet
  var tv: Timeval
  tv.tv_sec = 0.Time; tv.tv_usec = 0
  let fd = getFileHandle(stdin)

  var oldTermios, rawTermios: Termios
  if fd.tcGetAttr(oldTermios.addr) != -1:
    rawTermios = oldTermios
    rawTermios.c_iflag = rawTermios.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
    rawTermios.c_lflag = rawTermios.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
    rawTermios.c_cc[VMIN] = 1.cuchar
    rawTermios.c_cc[VTIME] = 0.cuchar
    discard fd.tcSetAttr(TCSADRAIN, rawTermios.addr)

  while true:
    s.FD_ZERO; fd.FD_SET(s)
    if posix.select(1, s.addr, nil, nil, tv.addr) <= 0:
      break
    discard posix.read(fd, buf[0].addr, 256)

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
