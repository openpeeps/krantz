# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[asyncdispatch, cpuinfo, os, sequtils, strformat, strutils]
import chachachat/llmclient

import ./llm
import ./spinny

when defined(macosx):
  proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
                    newp: pointer; newlen: csize_t): cint {.
                    importc, header: "<sys/sysctl.h>".}

  proc sysctlString(name: string): string =
    var size: csize_t = 0
    if sysctlbyname(name.cstring, nil, addr(size), nil, 0) != 0: return ""
    if size == 0: return ""
    result = newString(size)
    if sysctlbyname(name.cstring, result.cstring, addr(size), nil, 0) != 0:
      return ""
    let z = result.find('\0')
    if z >= 0: result.setLen(z)

  proc sysctlInt64(name: string): int64 =
    var v: int64 = 0
    var size = sizeof(v).csize_t
    if sysctlbyname(name.cstring, addr(v), addr(size), nil, 0) == 0:
      result = v

var gMachineInfo = ""

proc machineInfo(): string =
  if gMachineInfo.len > 0: return gMachineInfo
  var parts: seq[string]
  when defined(macosx):
    let ver = sysctlString("kern.osproductversion")
    parts.add("OS: macOS" & (if ver.len > 0: " " & ver else: ""))
    let cpu = sysctlString("machdep.cpu.brand_string").strip()
    parts.add("cpu: " & (if cpu.len > 0: cpu else: $hostCPU) & " (" & $countProcessors() & " cores)")
    let mem = sysctlInt64("hw.memsize")
    if mem > 0:
      parts.add("memory: " & fmt"{float(mem) / 1073741824.0:.1f} GB")
  else:
    parts.add("OS: " & $hostOS)
    parts.add("cpu: " & $countProcessors() & " cores")
    when defined(linux):
      try:
        for line in readFile("/proc/meminfo").splitLines():
          if line.startsWith("MemTotal:"):
            let kb = line.split()[1].parseInt()
            parts.add("memory: " & fmt"{float(kb) * 1024.0 / 1073741824.0:.1f} GB")
            break
      except CatchableError:
        discard
  parts.add("arch: " & $hostCPU)
  result = parts.join(", ")
  gMachineInfo = result

proc systemPromptText(): string =
  result = "You are a shell command assistant embedded in the krantz terminal shell running on " &
    machineInfo() &
    ". The user asks how to perform a task using a command-line tool. Reply with ONLY the exact " &
    "command(s) required to accomplish the task — no explanation, no commentary, no markdown, no " &
    "code fences, no backticks, and no surrounding text. If more than one command is needed, output " &
    "each command on its own line in order. If no valid command exists, reply with exactly: error"

proc isChatCommand*(line: string): bool =
  line.len > 0 and line[0] == '?'

proc chatQuery*(line: string): string =
  if line.len <= 1: return ""
  line[1..^1].strip()

proc chatMessages(query: string): seq[UserMessage] =
  result = @[
    UserMessage(role: UserMessageRole.system, content: systemPromptText()),
    UserMessage(role: UserMessageRole.user, content: query)
  ]

proc chatRequest(query: string): Future[string] {.async.} =
  let store = openLLMStore()
  if store.isNil:
    return "error: LLM store unavailable"
  let providers = listProviders(store)
  if providers.len == 0:
    return "no LLM provider configured — run 'krantz llm' first"
  let defaultName = getDefaultProvider(store)
  var p = providers[^1]
  for candidate in providers:
    if candidate.name == defaultName:
      p = candidate
      break
  let client = newLlmClient(p.address, p.key, p.model)
  try:
    let response = await client.chat(chatMessages(query), defaultOpts,
      proc(chunk: ResponseChunk) = discard)
    result = response.chunks
      .filterIt(it.chunkType == chunkContent)
      .mapIt(it.text)
      .join("").strip()
  except CatchableError as e:
    result = "error: " & e.msg

proc handleChatCommand*(line: string): int =
  let query = chatQuery(line)
  let spinny = newSpinny("Loading...", skDots, time = true)
  spinny.start()
  let response = waitFor(chatRequest(query))
  spinny.success(response)
  result = 0
