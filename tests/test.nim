# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, osproc]

const nimSuite = currentSourcePath().parentDir() / "test_interactive.nim"

proc findKrantz(): string =
  let envBin = getEnv("KRANTZ")
  if envBin.len > 0:
    return envBin
  let build = execCmdEx("clue build", options = {poStdErrToStdOut, poUsePath})
  if build.exitCode != 0:
    stderr.writeLine "krantz build failed:\n" & build.output
    quit(1)
  result = getCurrentDir() / "bin" / "krantz"

proc main() =
  let krantz = findKrantz()
  echo "testing krantz at: ", krantz
  putEnv("KRANTZ", krantz)
  var cmd = "nim r " & quoteShell(nimSuite)
  for i in 1 .. paramCount():
    cmd.add(" " & quoteShell(paramStr(i)))
  let (output, code) = execCmdEx(cmd, options = {poStdErrToStdOut, poUsePath})
  stdout.write(output)
  quit(code)

main()
