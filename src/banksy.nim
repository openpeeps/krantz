import std/[strutils, os]

import banksy/[config, history, parser, executor, policy, prompt, term, types]

proc runShell() =
  let cfg = loadConfig()
  let engine = newPolicyEngine(cfg)
  var state = ShellState(
    config: cfg,
    policy: engine,
    lastExitCode: 0,
    shouldExit: false,
    prevDir: ""
  )
  openHistoryStore(state)
  var historyList = loadAllHistory(state)
  var histIdx = -1
  var savedNewInput = ""

  let interactive = isTerminal(0)
  var termMode: ConsoleMode
  if interactive:
    termMode = enableRawMode()

  while not state.shouldExit:
    let cwd = getCurrentDir()
    if cwd != state.lastCwd:
      state.lastCwd = cwd
      state.cachedBranch = if state.config.prompt.git: getGitBranch() else: ""

    let promptStr = makePrompt(state.lastExitCode, state.config.prompt, state.cachedBranch)

    var buf = ""
    var line = ""

    block readInput:
      while true:
        if interactive:
          let result = readLine(promptStr, buf)
          case result.kind
          of rrLine:
            line = result.line
            histIdx = -1
            break readInput
          of rrCancel:
            buf.setLen(0)
            histIdx = -1
            continue
          of rrEof:
            state.shouldExit = true
            break readInput
          of rrNav:
            if histIdx == -1:
              savedNewInput = buf
            if result.navUp and historyList.len > 0:
              if histIdx == -1:
                histIdx = historyList.len - 1
              elif histIdx > 0:
                dec histIdx
              buf = historyList[histIdx]
              redraw(promptStr, buf)
            elif not result.navUp:
              if histIdx >= 0:
                inc histIdx
                if histIdx < historyList.len:
                  buf = historyList[histIdx]
                  redraw(promptStr, buf)
                else:
                  histIdx = -1
                  buf = savedNewInput
                  redraw(promptStr, buf)
            continue
        else:
          stdout.write(promptStr)
          stdout.flushFile()
          try:
            line = stdin.readLine()
          except EOFError:
            echo ""
            state.shouldExit = true
          break readInput

    let trimmed = line.strip()
    if trimmed.len == 0:
      continue

    let parsed = parseLine(trimmed)

    var policyBlocked = false
    block checkPolicy:
      for pipe in parsed.pipelines:
        for cmd in pipe.commands:
          if cmd.args.len == 0: continue
          let policyResult = engine.check(cmd.args[0])
          if policyResult.kind == prDenied:
            stderr.writeLine policyResult.message
            policyBlocked = true
            break checkPolicy

    if policyBlocked:
      state.lastExitCode = 1
    else:
      state.lastExitCode = executeParsedLine(parsed, state)
      if trimmed.split()[0] != "history" and trimmed.split()[0] != "exit":
        addHistory(state, trimmed)
        historyList.add(trimmed)

  if interactive:
    disableRawMode(termMode)

proc printUsage() =
  echo "Usage: banksy [command]"
  echo ""
  echo "Commands:"
  echo "  config               Show current configuration"
  echo "  config init          Create default config file"
  echo "  config show          Show current configuration"
  echo "  config deny list     List denied commands"
  echo "  config deny add      <cmd>  Add command to deny list"
  echo "  config deny remove   <cmd>  Remove command from deny list"
  echo "  help                 Show this help"
  echo ""
  echo "Run without arguments to enter the REPL shell."

proc dispatchCli(args: seq[string]) =
  if args.len == 0 or args[0] in ["help", "--help", "-h"]:
    printUsage()
    return

  case args[0]
  of "config":
    if args.len == 1 or args[1] in ["show", "--show"]:
      printConfig()
    elif args[1] == "init":
      initConfig()
    elif args[1] == "deny":
      if args.len < 3 or args[2] in ["list", "--list"]:
        configDenyList()
      elif args[2] == "add" and args.len >= 4:
        configDenyAdd(args[3])
      elif args[2] == "remove" and args.len >= 4:
        configDenyRemove(args[3])
      else:
        stderr.writeLine "usage: banksy config deny list|add <cmd>|remove <cmd>"
        quit(1)
    else:
      stderr.writeLine "usage: banksy config [init|show|deny]"
      quit(1)
  else:
    stderr.writeLine "banksy: unknown command: ", args[0]
    printUsage()
    quit(1)

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    runShell()
  else:
    dispatchCli(args)
