import std/[algorithm, strutils, os]
import ./banksy/private/noise
import banksy/[config, env, history, parser, executor, policy, prompt, term, types]

proc runShell() =
  loadShellEnv()
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

  let interactive = isTerminal(0)
  if interactive:
    initTerminal()
    for h in historyList:
      gNoise.historyAdd(h)

  while not state.shouldExit:
    let cwd = getCurrentDir()
    if cwd != state.lastCwd:
      state.lastCwd = cwd
      state.cachedBranch = if state.config.prompt.git: getGitBranch() else: ""

    let promptStr = makePrompt(state.lastExitCode, state.config.prompt, state.cachedBranch)

    var line = ""

    if interactive:
      let promptStyler = makePromptStyler(state.lastExitCode, state.config.prompt, state.cachedBranch)
      let (success, input) = readLineInput(promptStyler)
      if not success:
        let kt = gNoise.getKeyType()
        if kt == ktCtrlD:
          echo ""
          state.shouldExit = true
          break
        continue
      line = input
    else:
      stdout.write(promptStr)
      stdout.flushFile()
      try:
        line = stdin.readLine()
      except EOFError:
        echo ""
        state.shouldExit = true
        break

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
      let cmdName = trimmed.split()[0]
      if cmdName != "history" and cmdName != "exit":
        if historyList.len == 0 or historyList[^1] != trimmed:
          addHistory(state, trimmed)
          historyList.add(trimmed)
          gNoise.historyAdd(trimmed)

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
  echo "  complete <word>      Generate shell completions"
  echo "  help                 Show this help"
  echo ""
  echo "Run without arguments to enter the REPL shell."

proc doComplete(word: string) =
  var dir = "."
  var prefix = word

  if word.contains("/"):
    dir = word.parentDir().expandTilde()
    prefix = word.extractFilename()
  else:
    dir = "."
    prefix = word

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
      echo c

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
  of "complete":
    if args.len >= 2:
      doComplete(args[1])
    else:
      stderr.writeLine "usage: banksy complete <word>"
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
