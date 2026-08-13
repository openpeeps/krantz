version       = "0.1.2"
author        = "George Lemon"
description   = "A fast ZSH alternative"
license       = "MIT"
srcDir        = "src"
bin           = @["krantz"]

requires "nim >= 2.2.10"
requires "openparser >= 0.1.8"
requires "boogie >= 0.1.1"
requires "chachachat >= 0.1.0"
requires "floof >= 1.0.0"

task test, "Run the interactive pty test suite":
  exec "nim r tests/test.nim"
