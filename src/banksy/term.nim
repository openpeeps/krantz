import posix

const
  ECHO = culong(0x00000008)
  ICANON = culong(0x00000100)
  ISIG = culong(0x00000080)
  IEXTEN = culong(0x00000400)
  ICRNL = culong(0x00000100)
  IXON = culong(0x00000200)
  OPOST = culong(0x00000001)
  TCSAFLUSH = 2
  VMIN = 16
  VTIME = 17

type
  Termios {.importc: "struct termios", header: "<termios.h>", bycopy.} = object
    c_iflag: culong
    c_oflag: culong
    c_cflag: culong
    c_lflag: culong
    c_cc: array[20, uint8]
    c_ispeed: culong
    c_ospeed: culong

proc tcgetattr(fd: cint; term: var Termios): cint {.importc, header: "<termios.h>".}
proc tcsetattr(fd: cint; opt: cint; term: var Termios): cint {.importc, header: "<termios.h>".}

type
  ConsoleMode* = object
    orig: Termios

  ReadResultKind* = enum
    rrLine
    rrCancel
    rrEof
    rrNav

  ReadResult* = object
    case kind*: ReadResultKind
    of rrLine:
      line*: string
    of rrCancel, rrEof: discard
    of rrNav:
      navUp*: bool

proc enableRawMode*(): ConsoleMode =
  var raw: Termios
  discard tcgetattr(0, raw)
  result.orig = raw
  raw.c_iflag = raw.c_iflag and not (ICRNL or IXON)
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or ISIG or IEXTEN)
  raw.c_cc[VMIN] = 1
  raw.c_cc[VTIME] = 0
  discard tcsetattr(0, TCSAFLUSH, raw)

proc disableRawMode*(cm: ConsoleMode) =
  var orig = cm.orig
  discard tcsetattr(0, TCSAFLUSH, orig)

proc isTerminal*(fd: cint): bool =
  posix.isatty(fd) != 0

proc readKey*(): int =
  var c: char
  let n = posix.read(0, addr c, 1)
  if n <= 0: return -100
  if c == '\x1b':
    var restore: Termios
    discard tcgetattr(0, restore)
    restore.c_cc[VMIN] = 0
    restore.c_cc[VTIME] = 1
    discard tcsetattr(0, TCSAFLUSH, restore)
    var seq: array[2, char]
    let n1 = posix.read(0, addr seq[0], 1)
    restore.c_cc[VMIN] = 1
    restore.c_cc[VTIME] = 0
    discard tcsetattr(0, TCSAFLUSH, restore)
    if n1 <= 0 or seq[0] != '[':
      return 27
    if posix.read(0, addr seq[1], 1) <= 0:
      return 27
    case seq[1]
    of 'A': return -1
    of 'B': return -2
    of 'C': return -3
    of 'D': return -4
    else: return 27
  return int(c)

proc redraw*(prompt: string, buf: string) =
  stdout.write("\r\x1b[K" & prompt & buf)
  stdout.flushFile()

proc readLine*(prompt: string, buf: var string): ReadResult =
  redraw(prompt, buf)
  while true:
    let key = readKey()
    case key
    of 10, 13:
      if buf.len == 0:
        stdout.write("\r\n")
        stdout.flushFile()
        return ReadResult(kind: rrCancel)
      stdout.write("\r\n")
      stdout.flushFile()
      return ReadResult(kind: rrLine, line: buf)
    of 3:
      buf.setLen(0)
      stdout.write("\r\n")
      stdout.flushFile()
      return ReadResult(kind: rrCancel)
    of 4:
      if buf.len == 0:
        return ReadResult(kind: rrEof)
    of 127:
      if buf.len > 0:
        buf.setLen(buf.len - 1)
        redraw(prompt, buf)
    of -1:
      return ReadResult(kind: rrNav, navUp: true)
    of -2:
      return ReadResult(kind: rrNav, navUp: false)
    of -100:
      return ReadResult(kind: rrEof)
    of 27:
      discard
    else:
      if key >= 32 and key <= 126:
        buf.add(char(key))
        stdout.write(char(key))
        stdout.flushFile()
