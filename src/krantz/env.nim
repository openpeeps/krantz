# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, posix, strutils]

proc loadShellEnv*() =
  let pw = getpwuid(getuid())
  let shell =
    if pw != nil and $pw.pw_shell != "" : $pw.pw_shell
    else: getEnv("SHELL")
  if shell.len == 0: return
  let shellName = shell.splitPath().tail

  var pipefds: array[2, cint]
  if posix.pipe(pipefds) != 0: return
  let pid = fork()
  if pid < 0:
    discard close(pipefds[0]); discard close(pipefds[1])
    return
  if pid == 0:
    discard close(pipefds[0])
    discard dup2(pipefds[1], 1)
    discard close(pipefds[1])
    discard execlp(shell.cstring, shellName.cstring, "-l".cstring, "-c".cstring,
      "source ~/.zshrc 2>/dev/null; source ~/.profile 2>/dev/null; env -0".cstring, nil)
    quit(1)
  discard close(pipefds[1])
  var buf: array[65536, char]
  var output = ""
  while true:
    let n = posix.read(pipefds[0], buf[0].addr, 65536)
    if n <= 0: break
    for j in 0..<int(n): output.add(buf[j])
  discard close(pipefds[0])
  var status: cint = 0
  discard waitpid(pid, status, 0)
  if not (WIFEXITED(status) and WEXITSTATUS(status) == 0):
    return
  if output.len == 0: return

  for entry in output.split('\0'):
    if entry.len == 0: continue
    let eq = entry.find('=')
    if eq > 0:
      putEnv(entry[0..<eq], entry[eq+1..^1])
