import std/[algorithm, os, posix, strutils]
import ./private/noise

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
  let line = self.getLine()
  var dir = "."
  var prefix = text

  # find the last occurrence of text in the line
  var idx = line.len - text.len
  while idx >= 0 and line[idx..idx+text.len-1] != text:
    dec idx
  if idx > 0:
    let before = line[0..<idx]
    var lastSpace = -1
    for i in countdown(before.len - 1, 0):
      if before[i] in {' ', '\t'}:
        lastSpace = i
        break
    let pathPart =
      if lastSpace >= 0: before[lastSpace+1..^1]
      else: before
    if pathPart.len > 0:
      dir = pathPart.expandTilde()

  var candidates: seq[string]
  try:
    for kind, path in walkDir(dir):
      let name = path.extractFilename()
      if name.len >= prefix.len and name.toLowerAscii()[0..<prefix.len] == prefix.toLowerAscii():
        candidates.add(name)
  except OSError:
    discard
  if candidates.len > 0:
    sort(candidates, cmpIgnoreCase)
    for c in candidates:
      self.addCompletion(c)
  result = candidates.len

proc initTerminal*() =
  gNoise = Noise.init()
  gNoise.setCompletionHook(completeCallback)
  gNoise.historySetMaxLen(1000)

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
