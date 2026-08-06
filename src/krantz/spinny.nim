# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz
#
# Automated terminal spinners, rewritten into krantz core from the
# kapsis `spinny` package. Frames are from cli-spinners (MIT).

import std/[os, terminal, times, monotimes, strutils]

type
  Spinner* = object
    interval*: int
    frames*: seq[string]

  Spinny* = ref object
    text: string
    running: bool
    frames: seq[string]
    frame: string
    interval: int
    customSymbol: bool
    trackTime: bool
    startTime: MonoTime

  EventKind = enum
    Stop, StopSuccess, StopError,
    SymbolChange, TextChange

  SpinnyEvent = tuple
    kind: EventKind
    payload: string

var spinnyThread: Thread[Spinny]
var spinnyChannel: Channel[SpinnyEvent]

proc fgCyan(s: string): string = "\e[36m" & s & "\e[0m"
proc fgRed(s: string): string = "\e[31m" & s & "\e[0m"
proc bold(s: string): string = "\e[1m" & s & "\e[0m"

proc newSpinny*(text: string, s: Spinner, time = false): Spinny =
  result = Spinny(
    text: text,
    running: true,
    frames: s.frames,
    customSymbol: false,
    interval: s.interval,
    trackTime: time
  )

proc setSymbol*(spinny: Spinny, symbol: string) =
  spinnyChannel.send((SymbolChange, symbol))

proc setText*(spinny: Spinny, text: string) =
  spinnyChannel.send((TextChange, text))

proc handleEvent(spinny: Spinny, eventData: SpinnyEvent): bool =
  result = true
  case eventData.kind
  of Stop:
    result = false
  of SymbolChange:
    spinny.customSymbol = true
    spinny.frame = eventData.payload
  of TextChange:
    spinny.text = eventData.payload
  of StopSuccess:
    spinny.customSymbol = true
    spinny.frame = "✨".bold.fgCyan
    spinny.text = eventData.payload.fgCyan
  of StopError:
    spinny.customSymbol = true
    spinny.frame = "✖".bold.fgRed
    spinny.text = eventData.payload

proc timeDiff(d: Duration): string =
  result = $int(d.inSeconds()) & "sec"

proc spinnyLoop(spinny: Spinny) {.thread.} =
  var frameCounter = 0
  if spinny.trackTime:
    spinny.startTime = getMonoTime()

  while spinny.running:
    let data = spinnyChannel.tryRecv()
    if data.dataAvailable:
      if not spinny.handleEvent(data.msg):
        spinnyChannel.close()
        spinnyChannel = default(typeof(spinnyChannel))
        spinny.running = false

    stdout.flushFile()
    if not spinny.customSymbol:
      spinny.frame = spinny.frames[frameCounter]
    var text = spinny.text
    if spinny.trackTime:
      text = timeDiff(getMonoTime() - spinny.startTime) & " " & text

    eraseLine()
    stdout.write(spinny.frame & " " & text)
    stdout.flushFile()

    sleep(spinny.interval)

    if frameCounter >= spinny.frames.len - 1:
      frameCounter = 0
    else:
      frameCounter += 1

proc start*(spinny: Spinny) =
  if spinnyThread.running():
    raise newException(ValueError, "Previous Spinny instance wasn't stopped!")
  spinnyChannel.open()
  createThread(spinnyThread, spinnyLoop, spinny)

proc stop(spinny: Spinny, kind: EventKind, payload = "") =
  spinnyChannel.send((kind, payload))
  if kind != Stop:
    spinnyChannel.send((Stop, ""))
  joinThread(spinnyThread)
  echo ""

proc stop*(spinny: Spinny) =
  spinny.stop(Stop)

proc success*(spinny: Spinny, msg: string) =
  spinny.stop(StopSuccess, msg)

proc success*(spinny: Spinny) =
  spinny.stop(StopSuccess)

proc error*(spinny: Spinny, msg: string) =
  spinny.stop(StopError, msg)

# Spinner frames from https://github.com/sindresorhus/cli-spinners (MIT)
const
  skDots* = Spinner(interval: 80, frames: @["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
  skDots2* = Spinner(interval: 80, frames: @["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"])
  skDots3* = Spinner(interval: 80, frames: @["⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓"])
  skLine* = Spinner(interval: 130, frames: @["-", "\\", "|", "/"])
  skLine2* = Spinner(interval: 100, frames: @["⠂", "-", "–", "—", "–", "-"])
  skPipe* = Spinner(interval: 100, frames: @["┤", "┘", "┴", "└", "├", "┌", "┬", "┐"])
  skSimpleDots* = Spinner(interval: 400, frames: @[".  ", ".. ", "...", "   "])
  skSimpleDotsScrolling* = Spinner(interval: 200, frames: @[".  ", ".. ", "...", " ..", "  .", "   "])
  skStar* = Spinner(interval: 70, frames: @["✶", "✸", "✹", "✺", "✹", "✷"])
  skStar2* = Spinner(interval: 80, frames: @["+", "x", "*"])
  skBouncingBar* = Spinner(interval: 80, frames: @["[    ]", "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]", "[   =]", "[    ]", "[   =]", "[  ==]", "[ ===]", "[====]", "[=== ]", "[==  ]", "[=   ]"])
  skBouncingBall* = Spinner(interval: 80, frames: @["( ●    )", "(  ●   )", "(   ●  )", "(    ● )", "(     ●)", "(    ● )", "(   ●  )", "(  ●   )", "( ●    )", "(●     )"])
  skPoint* = Spinner(interval: 125, frames: @["∙∙∙", "●∙∙", "∙●∙", "∙∙●", "∙∙∙"])
  skCircleQuarters* = Spinner(interval: 120, frames: @["◴", "◷", "◶", "◵"])
  skArc* = Spinner(interval: 100, frames: @["◜", "◠", "◝", "◞", "◡", "◟"])
  skTriangle* = Spinner(interval: 50, frames: @["◢", "◣", "◤", "◥"])
  skGrowVertical* = Spinner(interval: 120, frames: @["▁", "▃", "▄", "▅", "▆", "▇", "▆", "▅", "▄", "▃"])
  skGrowHorizontal* = Spinner(interval: 120, frames: @["▏", "▎", "▍", "▌", "▋", "▊", "▉", "▊", "▋", "▌", "▍", "▎"])
  skBoxBounce* = Spinner(interval: 120, frames: @["▖", "▘", "▝", "▗"])
  skArrow* = Spinner(interval: 100, frames: @["←", "↖", "↑", "↗", "→", "↘", "↓", "↙"])
  skArrow3* = Spinner(interval: 120, frames: @["▹▹▹▹▹", "▸▹▹▹▹", "▹▸▹▹▹", "▹▹▸▹▹", "▹▹▹▸▹", "▹▹▹▹▸"])
  skClock* = Spinner(interval: 100, frames: @["🕛 ", "🕐 ", "🕑 ", "🕒 ", "🕓 ", "🕔 ", "🕕 ", "🕖 ", "🕗 ", "🕘 ", "🕙 ", "🕚 "])
  skEarth* = Spinner(interval: 180, frames: @["🌍 ", "🌎 ", "🌏 "])
  skMoon* = Spinner(interval: 80, frames: @["🌑 ", "🌒 ", "🌓 ", "🌔 ", "🌕 ", "🌖 ", "🌗 ", "🌘 "])
  skWeather* = Spinner(interval: 100, frames: @["☀️ ", "☀️ ", "☀️ ", "🌤 ", "⛅️ ", "🌥 ", "☁️ ", "🌧 ", "🌨 ", "🌧 ", "🌨 ", "🌧 ", "🌨 ", "⛈ ", "🌨 ", "🌧 ", "🌨 ", "☁️ ", "🌥 ", "⛅️ ", "🌤 ", "☀️ ", "☀️ "])
  skChristmas* = Spinner(interval: 400, frames: @["🌲", "🎄"])
  skMonkey* = Spinner(interval: 300, frames: @["🙈 ", "🙈 ", "🙉 ", "🙊 "])
  skHamburger* = Spinner(interval: 100, frames: @["☱", "☲", "☴"])
  skNoise* = Spinner(interval: 100, frames: @["▓", "▒", "░"])
  skShark* = Spinner(interval: 120, frames: @["▐|\\____________▌", "▐_|\\___________▌", "▐__|\\__________▌", "▐___|\\_________▌", "▐____|\\________▌", "▐_____|\\_______▌", "▐______|\\______▌", "▐_______|\\_____▌", "▐________|\\____▌", "▐_________|\\___▌", "▐__________|\\__▌", "▐___________|\\_▌", "▐____________|\\▌", "▐____________/|▌", "▐___________/|_▌", "▐__________/|__▌", "▐_________/|___▌", "▐________/|____▌", "▐_______/|_____▌", "▐______/|______▌", "▐_____/|_______▌", "▐____/|________▌", "▐___/|_________▌", "▐__/|__________▌", "▐_/|___________▌", "▐/|____________▌"])
