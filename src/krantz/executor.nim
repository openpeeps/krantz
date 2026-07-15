# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, strutils, tables]
import posix

import ./types
import ./history

proc toCstringArray(a: seq[string]): cstringArray =
  result = cast[cstringArray](alloc0(sizeof(cstring) * (a.len + 1)))
  for i in 0..<a.len:
    result[i] = cstring(a[i])

proc executePipeline*(pipe: Pipeline): int =
  let cmds = pipe.commands
  if cmds.len == 0: return 0

  var pids: seq[Pid]
  var pipes: seq[(cint, cint)]

  for i in 0..<cmds.len-1:
    var fds: array[2, cint]
    if posix.pipe(fds) != 0:
      return 1
    pipes.add((fds[0], fds[1]))

  for i, cmd in cmds:
    let pid = fork()
    if pid < 0: return 1

    if pid == 0:
      if i > 0:
        discard dup2(pipes[i-1][0], 0)
      if i < cmds.len - 1:
        discard dup2(pipes[i][1], 1)

      for p in pipes:
        discard close(p[0])
        discard close(p[1])

      for redir in cmd.redirects:
        case redir.kind
        of rkInput:
          let fd = posix.open(redir.target.cstring, O_RDONLY)
          if fd < 0:
            stderr.writeLine("banksy: " & redir.target & ": No such file or directory")
            quit(1)
          discard dup2(fd, 0); discard close(fd)
        of rkOutput:
          let fd = posix.open(redir.target.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
          if fd < 0:
            stderr.writeLine("banksy: " & redir.target & ": Cannot open")
            quit(1)
          discard dup2(fd, cint(redir.fd)); discard close(fd)
        of rkOutputAppend:
          let fd = posix.open(redir.target.cstring, O_WRONLY or O_CREAT or O_APPEND, 0o644)
          if fd < 0:
            stderr.writeLine("banksy: " & redir.target & ": Cannot open")
            quit(1)
          discard dup2(fd, cint(redir.fd)); discard close(fd)
        of rkFdDup:
          if redir.target == "-":
            discard close(cint(redir.fd))
          else:
            var targetFd: int
            if redir.target.len > 0 and redir.target[0] == '&':
              targetFd = parseInt(redir.target[1..^1])
            else:
              targetFd = parseInt(redir.target)
            discard dup2(cint(targetFd), cint(redir.fd))

      for v in cmd.envVars:
        putEnv(v[0], v[1])

      var argvSeq = @[cmd.args[0]]
      if cmd.args.len > 1:
        for a in cmd.args[1..^1]:
          argvSeq.add(a)

      let argv = toCstringArray(argvSeq)
      discard execvp(cstring(cmd.args[0]), argv)

      let e = errno
      if e == ENOENT:
        stderr.writeLine("banksy: command not found: " & cmd.args[0])
        quit(127)
      elif e == EACCES:
        stderr.writeLine("banksy: " & cmd.args[0] & ": Permission denied")
        quit(126)
      else:
        stderr.writeLine("banksy: " & cmd.args[0] & ": error")
        quit(126)

    else:
      pids.add(pid)

  for p in pipes:
    discard close(p[0])
    discard close(p[1])

  if pipe.background:
    echo '[', pids[^1], "] ", pids[^1]
    return 0

  var lastStatus: cint = 0
  for pid in pids:
    var status: cint = 0
    while waitpid(pid, status, 0) < 0 and errno == EINTR:
      discard
    lastStatus = status

  if WIFEXITED(lastStatus):
    return int(WEXITSTATUS(lastStatus))
  if WIFSIGNALED(lastStatus):
    return 128 + int(WTERMSIG(lastStatus))
  return 1

proc executeParsedLine*(parsed: ParsedLine, state: var ShellState): int =
  if parsed.pipelines.len == 0: return 0

  for i, pipe in parsed.pipelines:
    if i > 0 and i - 1 < parsed.separators.len:
      case parsed.separators[i-1]
      of psAndThen:
        if state.lastExitCode != 0: continue
      of psOrElse:
        if state.lastExitCode == 0: continue
      of psSequential:
        discard

    if pipe.commands.len > 0:
      let firstCmd = pipe.commands[0]

      if firstCmd.args.len == 0:
        result = 0; state.lastExitCode = 0
        continue

      if firstCmd.args.len > 0:
        let cmdName = firstCmd.args[0]
        if cmdName == "export":
          for i in 1..<firstCmd.args.len:
            let varName = firstCmd.args[i]
            if state.vars.hasKey(varName):
              putEnv(varName, state.vars[varName])
          result = 0; state.lastExitCode = 0; continue
        if cmdName == "unset":
          for i in 1..<firstCmd.args.len:
            let varName = firstCmd.args[i]
            state.vars.del(varName)
            delEnv(varName)
          result = 0; state.lastExitCode = 0; continue
        if cmdName == "exit":
          state.shouldExit = true
          if firstCmd.args.len > 1:
            result = parseInt(firstCmd.args[1])
          state.lastExitCode = result
          return
        if cmdName == "history":
          for e in getHistory(state):
            echo e[0], "  ", e[1]
          result = 0; state.lastExitCode = 0; continue
        if cmdName.len >= 2 and cmdName != "." and cmdName.allCharsInSet({'.', '/'}):
          state.prevDir = getCurrentDir()
          try:
            setCurrentDir(cmdName)
          except OSError:
            stderr.writeLine("banksy: cd: " & cmdName & ": No such file or directory")
            result = 1
            state.lastExitCode = 1
            continue
          result = 0
          state.lastExitCode = 0
          continue
        if cmdName == "cd":
          if firstCmd.args.len == 1:
            let home = getHomeDir()
            state.prevDir = getCurrentDir()
            setCurrentDir(home)
          elif firstCmd.args[1] == "-":
            let tmp = getCurrentDir()
            setCurrentDir(state.prevDir)
            state.prevDir = tmp
          else:
            state.prevDir = getCurrentDir()
            try:
              setCurrentDir(firstCmd.args[1])
            except OSError:
              stderr.writeLine("banksy: cd: " & firstCmd.args[1] & ": No such file or directory")
              result = 1
              state.lastExitCode = 1
              continue
          result = 0
          state.lastExitCode = 0
          continue

        if cmdName == "trash":
          if firstCmd.args.len == 1:
            stderr.writeLine("banksy: trash: missing operand")
            result = 1
            state.lastExitCode = 1
            continue
          let trashDir = getHomeDir() / ".Trash"
          var hadError = false
          for i in 1..<firstCmd.args.len:
            let src = firstCmd.args[i]
            try:
              moveFile(src, trashDir / src.splitPath().tail)
            except OSError:
              stderr.writeLine("banksy: trash: cannot move '" & src & "': No such file or directory")
              hadError = true
          result = if hadError: 1 else: 0
          state.lastExitCode = result
          continue

    result = executePipeline(pipe)
    state.lastExitCode = result
