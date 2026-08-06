# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, osproc]

const pyFile = currentSourcePath().parentDir() / "test_interactive.py"

proc findKrantz(): string =
  let envBin = getEnv("KRANTZ")
  if envBin.len > 0:
    return envBin
  let build = execCmdEx("nimble build -y", options = {poStdErrToStdOut, poUsePath})
  if build.exitCode != 0:
    stderr.writeLine "krantz build failed:\n" & build.output
    quit(1)
  result = getCurrentDir() / "krantz"

proc main() =
  let krantz = findKrantz()
  echo "testing krantz at: ", krantz
  putEnv("KRANTZ", krantz)
  let (output, code) = execCmdEx("python3 " & quoteShell(pyFile),
    options = {poStdErrToStdOut, poUsePath})
  stdout.write(output)
  quit(code)

main()
