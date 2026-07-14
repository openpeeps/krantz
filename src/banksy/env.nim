import std/[os, osproc, posix, strutils]

proc loadShellEnv*() =
  let pw = getpwuid(getuid())
  let shell =
    if pw != nil and $pw.pw_shell != "" : $pw.pw_shell
    else: getEnv("SHELL")
  if shell.len == 0: return

  let (output, exitCode) = execCmdEx(shell & " -l -c 'env -0'")
  if exitCode != 0: return
  if output.len == 0: return

  for entry in output.split('\0'):
    if entry.len == 0: continue
    let eq = entry.find('=')
    if eq > 0:
      putEnv(entry[0..<eq], entry[eq+1..^1])
