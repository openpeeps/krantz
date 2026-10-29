# krantz interactive test suite (pty-based, fully hermetic).
#
# Nim port of the original tests/test_interactive.py. Each test spawns krantz
# in a fresh pseudo-terminal with an isolated temp workspace + HOME, drives it
# with real keystrokes, and asserts on the output.
#
# Run directly:
#   KRANTZ=$PWD/bin/krantz nim r tests/test_interactive.nim [filter]
# Via nimble / clue:
#   nimble test
#   clue test
#
# `filter` follows std/unittest semantics: an exact test name
# ("completion-dash"), or a glob with a single `*` ("completion-*",
# "*dash*"). Also accepts "suite::test".

import std/[os, osproc, posix, strutils, sequtils, times, unittest, envvars,
    strtabs, tempfiles]
import termios

# --------------------------------------------------------------------------- #
# pty bindings (Nim stdlib has no forkpty wrapper)
# --------------------------------------------------------------------------- #

when defined(macosx):
  proc forkpty(amaster: ptr cint, name: cstring, termp: pointer,
      winp: pointer): Pid {.importc, header: "<util.h>".}
else:
  proc forkpty(amaster: ptr cint, name: cstring, termp: pointer,
      winp: pointer): Pid {.importc, header: "<pty.h>".}
  {.passL: "-lutil".}

var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

# --------------------------------------------------------------------------- #
# constants
# --------------------------------------------------------------------------- #

const
  PROMPT = "\xe2\x80\xba" # U+203A '›' prompt marker
  TAB = "\x09"
  SHIFT_TAB = "\x1b[Z"
  CR = "\r"
  ESC = "\x1b"
  CTRL_U = "\x15"

proc bs(n: int): string = "\x7f".repeat(n)

proc krantzBin(): string =
  let envBin = getEnv("KRANTZ")
  if envBin.len > 0:
    return envBin
  # matches tests/test.nim: built binary lands in bin/
  result = getCurrentDir() / "bin" / "krantz"

proc systemPath(): string =
  getEnv("KRANTZ_TEST_PATH", "/usr/bin:/bin")

# --------------------------------------------------------------------------- #
# fixture
# --------------------------------------------------------------------------- #

type
  Fixture = object
    root*: string
    home*: string
    work*: string
    bin*: string
    path*: string

proc newFixture(): Fixture =
  let root = createTempDir("krantz-test-", "")
  let home = root / "home"
  let work = root / "work"
  let bin = root / "bin"
  createDir(home)
  createDir(work)
  createDir(bin)
  createDir(home / ".Trash")
  createDir(home / "Creative Cloud Files")
  # fake executables -> deterministic command completion
  for name in ["gimp", "gitx", "grep2", "nan2"]:
    let p = bin / name
    writeFile(p, "")
    setFilePermissions(p, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec,
        fpGroupRead, fpOthersExec, fpOthersRead})
  # workspace fixtures
  for f in ["alpha.txt", "beta.txt", "gamma.log"]:
    writeFile(work / f, "")
  writeFile(work / ".hidden", "")
  writeFile(work / "krantz alias", "HELLO")
  for d in ["deep/path/here", "My Folder", "src", "subdir", "supra",
      "supranim-packages"]:
    createDir(work / d)
  result = Fixture(root: root, home: home, work: work, bin: bin,
      path: bin & ":" & systemPath())

proc cleanup(fix: Fixture) =
  try:
    removeDir(fix.root)
  except OSError:
    discard

# --------------------------------------------------------------------------- #
# pty shell
# --------------------------------------------------------------------------- #

type
  Shell = object
    fix: Fixture
    path: string
    cwd: string
    pid: Pid
    fd: cint
    output: string
    closed: bool

proc ptyFork(krantz, path, cwd, home: string): (Pid, cint) =
  var master: cint = -1
  let pid = forkpty(addr master, nil, nil, nil)
  if pid < 0:
    raise newException(OSError, "forkpty failed")
  if pid == 0:
    # child: minimal async-signal-safe-ish setup, then exec
    try:
      setCurrentDir(cwd)
    except OSError:
      quit(127)
    putEnv("TERM", "xterm-256color")
    putEnv("HOME", home)
    putEnv("PATH", path)
    let args = allocCStringArray([krantz])
    discard execv(krantz.cstring, args)
    quit(127)
  result = (pid, master)

proc newShell(fix: Fixture, path = "", cwd = ""): Shell =
  let p = if path.len > 0: path else: fix.path
  let c = if cwd.len > 0: cwd else: fix.work
  # krantz's loadShellEnv() runs a login shell that sources ~/.zshrc and
  # overwrites PATH, so pin PATH there to keep tests hermetic.
  writeFile(fix.home / ".zshrc", "export PATH='" & p & "'\n")
  let (pid, fd) = ptyFork(krantzBin(), p, c, fix.home)
  var win: IOctl_WinSize
  win.ws_row = 40
  win.ws_col = 80
  win.ws_xpixel = 0
  win.ws_ypixel = 0
  discard ioctl(fd, TIOCSWINSZ, addr win)
  result = Shell(fix: fix, path: p, cwd: c, pid: pid, fd: fd, output: "",
      closed: false)

proc pump(sh: var Shell, t = 0.4) =
  let start = epochTime()
  var buf = newString(4096)
  while epochTime() - start < t:
    var rfds: TFdSet
    FD_ZERO(rfds)
    FD_SET(sh.fd, rfds)
    var tv: Timeval
    tv.tv_sec = posix.Time(0)
    tv.tv_usec = Suseconds(50000)
    let n = select(sh.fd + 1, addr rfds, nil, nil, addr tv)
    if n > 0:
      let r = read(sh.fd, addr buf[0], 4096)
      if r > 0:
        sh.output.add(buf[0 ..< r])
      elif r == 0:
        return
      else:
        let e = errno
        if e == EINTR:
          continue
        return
    elif n < 0:
      if errno == EINTR:
        continue
      return

proc send(sh: var Shell, data: string, t = 0.5) =
  var off = 0
  while off < data.len:
    let w = write(sh.fd, unsafeAddr data[off], data.len - off)
    if w < 0:
      if errno == EINTR:
        continue
      break
    if w == 0:
      break
    off += w
  sh.pump(t)

proc waitPrompt(sh: var Shell, base = 0, timeout = 8.0): bool =
  let start = epochTime()
  while epochTime() - start < timeout:
    let lo = min(base, sh.output.len)
    if PROMPT in sh.output[lo ..^ 1]:
      return true
    sh.pump(0.1)
  let lo = min(base, sh.output.len)
  result = PROMPT in sh.output[lo ..^ 1]

proc segment(sh: Shell, base: int): string =
  if base >= sh.output.len:
    return ""
  result = sh.output[base ..^ 1]

proc runCmd(sh: var Shell, cmd: string, wait = 5.0): string =
  let base = sh.output.len
  sh.send(cmd & CR, t = 0.3)
  discard sh.waitPrompt(base, timeout = wait)
  result = sh.segment(base)

proc close(sh: var Shell) =
  if sh.closed:
    return
  sh.closed = true
  try:
    var eot = "\x04"
    discard write(sh.fd, addr eot[0], 1)
    sh.pump(0.3)
  except OSError, Defect:
    discard
  try:
    discard close(sh.fd)
  except OSError, Defect:
    discard
  try:
    discard kill(sh.pid, SIGKILL)
  except OSError, Defect:
    discard
  var status: cint = 0
  discard waitpid(sh.pid, status, WNOHANG)

# --------------------------------------------------------------------------- #
# CLI helpers
# --------------------------------------------------------------------------- #

proc cliEnv(fix: Fixture): StringTableRef =
  result = newStringTable(modeStyleInsensitive)
  for k, v in envPairs():
    result[k] = v
  result["HOME"] = fix.home
  result["PATH"] = fix.path
  result["TERM"] = "dumb"

proc runCli(fix: Fixture, args: openArray[string],
    cwd = ""): (string, int) =
  var cmd = quoteShell(krantzBin())
  for a in args:
    cmd.add(" " & quoteShell(a))
  let workDir = if cwd.len > 0: cwd else: fix.work
  let (output, code) = execCmdEx(cmd, workingDir = workDir,
      env = cliEnv(fix), options = {poStdErrToStdOut, poUsePath})
  result = (output, code)

proc makeGitRepo(dirpath: string): bool =
  var env = cliEnv(Fixture(root: "", home: getEnv("HOME"), work: dirpath,
      bin: "", path: getEnv("PATH")))
  env["GIT_AUTHOR_NAME"] = "krantz test"
  env["GIT_AUTHOR_EMAIL"] = "krantz@test"
  env["GIT_COMMITTER_NAME"] = "krantz test"
  env["GIT_COMMITTER_EMAIL"] = "krantz@test"
  proc run(args: varargs[string]): bool =
    var cmd = "git -c init.defaultBranch=main"
    for a in args:
      cmd.add(" " & quoteShell(a))
    let (_, code) = execCmdEx(cmd, workingDir = dirpath, env = env,
        options = {poStdErrToStdOut, poUsePath})
    code == 0
  if not run("init"):
    return false
  if not run("commit", "--allow-empty", "-m", "init"):
    return false
  if not run("branch", "feature"):
    return false
  result = true

# --------------------------------------------------------------------------- #
# cases
# --------------------------------------------------------------------------- #

suite "krantz interactive":
  test "completion-cycle":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    var base = sh.output.len
    sh.send("cat " & TAB, t = 0.4)
    var seg = sh.segment(base)
    checkpoint "first candidate = src (shortest, no slash)"
    check ("cat src" in seg) and ("cat src/" notin seg)
    checkpoint "no trailing space after dir"
    check "cat src " notin seg
    checkpoint "dotfiles hidden in listing"
    check ".hidden" notin seg

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    seg = sh.segment(base)
    checkpoint "second TAB stays at same level (deep, no descend)"
    check ("cat deep" in seg) and ("cat deep/" notin seg) and ("path" notin seg)

    base = sh.output.len
    sh.send("/", t = 0.3)
    seg = sh.segment(base)
    checkpoint "/ enters the folder (first child, unique -> slash)"
    check "cat deep/path/" in seg

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    checkpoint "TAB on single child stays"
    check "cat deep/path" in sh.segment(base)

    base = sh.output.len
    sh.send("/", t = 0.3)
    seg = sh.segment(base)
    checkpoint "adding / descends into path"
    check "cat deep/path/here/" in seg

  test "completion-single":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let base = sh.output.len
    sh.send("cat a" & TAB, t = 0.4)
    checkpoint "cat a<TAB> inserts alpha.txt"
    check "cat alpha.txt " in sh.segment(base)

  test "completion-unique-dir-slash":
    # Regression: a lone directory candidate used to render identically to
    # what was already typed (no trailing space, no slash), so `cd bi` + TAB
    # looked like it did nothing. The unique-match rule appends "/".
    let fix = newFixture()
    defer: fix.cleanup()
    createDir(fix.work / "bin")
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    # clearLine() resets the buffer so each keystroke sequence starts fresh
    proc clearLine(s: var Shell) = s.send(CTRL_U, t = 0.2)

    clearLine(sh)
    var base = sh.output.len
    sh.send("cd bi" & TAB, t = 0.4)
    checkpoint "cd bi<TAB> -> cd bin/ (only match)"
    check "cd bin/" in sh.segment(base)

    # an exact, already-typed dir name still gets the affordance
    clearLine(sh)
    base = sh.output.len
    sh.send("cd bin" & TAB, t = 0.4)
    checkpoint "cd bin<TAB> -> cd bin/ (exact dir match)"
    check "cd bin/" in sh.segment(base)

    # ambiguous prefixes stay slashless so TAB keeps cycling siblings
    createDir(fix.work / "binary")
    clearLine(sh)
    base = sh.output.len
    sh.send("cd bi" & TAB, t = 0.4)
    checkpoint "ambiguous cd bi<TAB> -> cd bin (no slash)"
    check ("cd bin" in sh.segment(base)) and ("cd bin/" notin sh.segment(base))
    base = sh.output.len
    sh.send(TAB, t = 0.3)
    checkpoint "ambiguous TAB cycles to cd binary (no slash)"
    check ("cd binary" in sh.segment(base)) and
      ("cd binary/" notin sh.segment(base))

    # files never get the slash
    clearLine(sh)
    base = sh.output.len
    sh.send("cat alph" & TAB, t = 0.4)
    checkpoint "unique file match still gets a trailing space, not a slash"
    check "cat alpha.txt " in sh.segment(base)

  test "completion-cd":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    var base = sh.output.len
    sh.send("cd " & TAB, t = 0.4)
    var got = sh.segment(base)
    checkpoint "cd lists dirs only (src first, shortest, no slash)"
    check ("cd src" in got) and ("cd src/" notin got)
    checkpoint "cd does not list files"
    check "alpha.txt" notin got

    base = sh.output.len
    sh.send(ESC, t = 0.3)
    base = sh.output.len
    sh.send("cd s" & TAB, t = 0.4)
    let seg = sh.segment(base)
    checkpoint "cd s<TAB> -> src (no slash)"
    check ("cd src" in seg) and ("cd src/" notin seg)

  test "completion-command":
    let fix = newFixture()
    defer: fix.cleanup()
    let binOnly = fix.bin

    block:
      var sh = newShell(fix, path = binOnly)
      defer: sh.close()
      require sh.waitPrompt()
      let base = sh.output.len
      sh.send("ech" & TAB, t = 0.4)
      checkpoint "builtin: ech<TAB> -> echo"
      check "echo" in sh.segment(base)

    block:
      var sh = newShell(fix, path = binOnly)
      defer: sh.close()
      require sh.waitPrompt()
      var base = sh.output.len
      sh.send("g" & TAB, t = 0.4)
      checkpoint "PATH: g<TAB> -> gimp"
      check "gimp" in sh.segment(base)
      base = sh.output.len
      sh.send(TAB, t = 0.3)
      checkpoint "PATH: cycle -> gitx"
      check "gitx" in sh.segment(base)

    block:
      var sh = newShell(fix, path = binOnly)
      defer: sh.close()
      require sh.waitPrompt()
      let base = sh.output.len
      sh.send("nan" & TAB, t = 0.4)
      checkpoint "PATH: nan<TAB> -> nan2"
      check "nan2" in sh.segment(base)

  test "completion-path":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let base = sh.output.len
    sh.send("cat deep/" & TAB, t = 0.4)
    let seg = sh.segment(base)
    checkpoint "cat deep/<TAB> -> deep/path/ (unique dir gets slash)"
    check ("cat deep/path/" in seg)

  test "completion-dotfile":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let base = sh.output.len
    sh.send("cat .h" & TAB, t = 0.4)
    checkpoint "cat .h<TAB> reveals .hidden"
    check "cat .hidden " in sh.segment(base)

  test "completion-tilde":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    var base = sh.output.len
    sh.send("cd ~/Crea" & TAB, t = 0.5)
    let seg1 = sh.segment(base)
    checkpoint "tilde completes with trailing slash (unique dir)"
    check ("cd ~/Creative\\ Cloud\\ Files/" in seg1)
    checkpoint "tilde not escaped"
    check "cd \\~/" notin seg1

    base = sh.output.len
    sh.send(bs(5) & TAB, t = 0.5) # drop "Files", re-tab
    let seg2 = sh.segment(base)
    checkpoint "recompletes after backspace"
    check "~/Creative\\ Cloud\\ Files" in seg2
    checkpoint "no doubled backslashes"
    check "\\\\" notin seg2

    base = sh.output.len
    sh.send(bs(15) & TAB, t = 0.5)
    let seg3 = sh.segment(base)
    checkpoint "no \\\\~ cascade"
    check "\\\\~" notin seg3
    checkpoint "keeps single backslash"
    check "~/Creative\\ Cloud\\ Files" in seg3

  test "completion-esc":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    sh.send("cat " & TAB, t = 0.4)
    let base = sh.output.len
    sh.send(ESC, t = 0.3)
    let seg = sh.segment(base)
    checkpoint "ESC cancels (no candidate)"
    check "alpha" notin seg
    checkpoint "ESC keeps command line"
    check "cat " in seg

  test "completion-space-accept":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    sh.send("cat b" & TAB, t = 0.4)
    let base = sh.output.len
    sh.send(" ", t = 0.3)
    let seg = sh.segment(base)
    checkpoint "space keeps single trailing space"
    check "cat beta.txt " in seg
    checkpoint "no double space"
    check "cat beta.txt  " notin seg

  test "completion-space-execute":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    var base = sh.output.len
    sh.send("cat kr" & TAB, t = 0.4)
    let segComp = sh.segment(base)

    base = sh.output.len
    sh.send(CR, t = 0.3)
    discard sh.waitPrompt(base, timeout = 5.0)
    let segRun = sh.segment(base)

    checkpoint "escaped candidate inserted"
    check "cat krantz\\ alias " in segComp
    checkpoint "command runs and prints content"
    check "HELLO" in segRun

  test "completion-fuzzy-cd":
    let fix = newFixture()
    defer: fix.cleanup()
    createDir(fix.work / "groovebox")
    writeFile(fix.work / "widget.txt", "widget")

    block:
      var sh = newShell(fix)
      defer: sh.close()
      require sh.waitPrompt()
      let base = sh.output.len
      sh.send("cat wget" & TAB, t = 0.5)
      checkpoint "cat wget<TAB> fuzzy -> widget.txt"
      check "cat widget.txt " in sh.segment(base)

    block:
      var sh = newShell(fix)
      defer: sh.close()
      require sh.waitPrompt()
      var base = sh.output.len
      sh.send("cd box" & TAB, t = 0.5)
      var seg = sh.segment(base)
      checkpoint "cd box<TAB> fuzzy -> groovebox/ (unique dir)"
      check "cd groovebox/" in seg
      sh.send(CR, t = 0.3)
      discard sh.waitPrompt(base, timeout = 5.0)
      seg = sh.runCmd("pwd")
      checkpoint "cd fuzzy completes into groovebox"
      check (fix.work / "groovebox") in seg

  test "completion-ls-mode":
    let fix = newFixture()
    defer: fix.cleanup()
    for d in ["src/docs", "src/krantz/somedir", "src/lib"]:
      createDir(fix.work / d)
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    var base = sh.output.len
    sh.send("cd sr" & TAB, t = 0.4)
    var seg = sh.segment(base)
    checkpoint "cd sr<TAB> -> cd src/ (unique dir)"
    check "cd src/" in seg

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    seg = sh.segment(base)
    checkpoint "TAB on unique dir has nothing to cycle"
    check "cd src/" in seg

    base = sh.output.len
    sh.send("/", t = 0.3)
    seg = sh.segment(base)
    checkpoint "/ enters src (lib, shortest, ambiguous -> no slash)"
    check ("cd src/lib" in seg) and ("cd src/lib/" notin seg)

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    checkpoint "TAB cycles child (docs)"
    check "cd src/docs" in sh.segment(base)

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    checkpoint "TAB switches candidate (krantz)"
    check "cd src/krantz" in sh.segment(base)

    base = sh.output.len
    sh.send("/", t = 0.3)
    seg = sh.segment(base)
    checkpoint "/ descends into krantz (unique child -> slash)"
    check "cd src/krantz/somedir/" in seg

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    checkpoint "TAB in empty dir stays"
    check "cd src/krantz/somedir" in sh.segment(base)

  test "completion-shortest":
    let fix = newFixture()
    defer: fix.cleanup()
    createDir(fix.work / "folder")
    createDir(fix.work / "folder_second")
    block:
      var sh = newShell(fix)
      defer: sh.close()
      require sh.waitPrompt()

      var base = sh.output.len
      sh.send("cd fo" & TAB, t = 0.4)
      var seg = sh.segment(base)
      checkpoint "cd fo<TAB> -> shortest folder first (no slash)"
      check (("cd folder" in seg) and ("cd folder/" notin seg) and
        ("folder_second" notin seg))

      base = sh.output.len
      sh.send(TAB, t = 0.3)
      seg = sh.segment(base)
      checkpoint "second TAB -> same-level folder_second (no slash)"
      check ("cd folder_second" in seg) and ("cd folder_second/" notin seg)

    block:
      let (output, _) = runCli(fix, ["complete", "fo"])
      let lines = output.splitLines().filterIt(it.len > 0)
      checkpoint "cli complete orders shortest first"
      check lines.len >= 2 and lines[0] == "folder" and lines[1] == "folder_second"

  test "completion-shift-tab":
    let fix = newFixture()
    defer: fix.cleanup()
    for f in ["zz_a.txt", "zz_bb.txt", "zz_ccc.txt"]:
      writeFile(fix.work / f, "")
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    # lone Shift+Tab starts at the last candidate (zsh-like)
    var base = sh.output.len
    sh.send("cat zz" & SHIFT_TAB, t = 0.4)
    checkpoint "lone Shift+Tab selects last candidate"
    check "cat zz_ccc.txt " in sh.segment(base)

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    checkpoint "TAB wraps forward to first"
    check "cat zz_a.txt " in sh.segment(base)

    base = sh.output.len
    sh.send(TAB, t = 0.3)
    checkpoint "TAB steps forward"
    check "cat zz_bb.txt " in sh.segment(base)

    base = sh.output.len
    sh.send(SHIFT_TAB, t = 0.3)
    checkpoint "Shift+Tab steps back"
    check "cat zz_a.txt " in sh.segment(base)

    base = sh.output.len
    sh.send(SHIFT_TAB, t = 0.3)
    checkpoint "Shift+Tab wraps back to last"
    check "cat zz_ccc.txt " in sh.segment(base)

  test "completion-dash":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let base = sh.output.len
    sh.send("cd supranim-" & TAB, t = 0.4)
    let seg = sh.segment(base)
    checkpoint "cd supranim-<TAB> -> supranim-packages/ (unique, not supra)"
    check (("cd supranim-packages/" in seg) and ("supranim-supra" notin seg))

  test "completion-equals":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let base = sh.output.len
    sh.send("cat X=al" & TAB, t = 0.4)
    checkpoint "cat X=al<TAB> keeps X= and completes the value"
    check "cat X=alpha.txt" in sh.segment(base)

  test "completion-redir":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let base = sh.output.len
    sh.send("cat >al" & TAB, t = 0.4)
    checkpoint "cat >al<TAB> keeps > and completes the target"
    check "cat >alpha.txt" in sh.segment(base)

  test "path-navigation":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    discard sh.runCmd("cd deep/path/here")
    var seg = sh.runCmd("pwd")
    checkpoint "cd deep/path/here"
    check (fix.work / "deep/path/here") in seg

    discard sh.runCmd("cd ../../")
    seg = sh.runCmd("pwd")
    checkpoint "cd ../../ (two levels)"
    check (fix.work / "deep") in seg

    seg = sh.runCmd("cd ..")
    seg = sh.runCmd("pwd")
    checkpoint "cd .. back to work"
    check fix.work in seg

    seg = sh.runCmd("cd subdir")
    seg = sh.runCmd("pwd")
    checkpoint "cd subdir"
    check (fix.work / "subdir") in seg

    seg = sh.runCmd("cd -")
    seg = sh.runCmd("pwd")
    checkpoint "cd - goes back"
    check fix.work in seg

    discard sh.runCmd("cd")
    seg = sh.runCmd("pwd")
    checkpoint "cd goes home"
    check fix.home in seg

  test "pipes-redirection":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    var seg = sh.runCmd("echo hi | tr a-z A-Z")
    checkpoint "pipe echo|tr"
    check "HI" in seg

    discard sh.runCmd("echo hello > out.txt")
    seg = sh.runCmd("cat out.txt")
    checkpoint "> write"
    check "hello" in seg

    discard sh.runCmd("echo second >> out.txt")
    seg = sh.runCmd("cat out.txt")
    checkpoint ">> append"
    check ("hello" in seg) and ("second" in seg)

    seg = sh.runCmd("cat < out.txt")
    checkpoint "< input"
    check "hello" in seg

    discard sh.runCmd("ls nope_xyz_123 2> err.txt")
    seg = sh.runCmd("cat err.txt")
    checkpoint "2> stderr redirect"
    check "nope_xyz_123" in seg

    seg = sh.runCmd("true && echo yes")
    checkpoint "&&"
    check "yes" in seg

    seg = sh.runCmd("false || echo ok")
    checkpoint "||"
    check "ok" in seg

  test "variables":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()

    var seg = sh.runCmd("echo $HOME")
    checkpoint "env var $HOME expansion"
    check fix.home in seg

    seg = sh.runCmd("echo ${HOME}")
    checkpoint "env var ${HOME} expansion"
    check fix.home in seg

    seg = sh.runCmd("export")
    checkpoint "export prints environment"
    check "PATH=" in seg

    seg = sh.runCmd("echo one")
    seg = sh.runCmd("history")
    checkpoint "history records commands"
    check "echo one" in seg

  test "history-concurrent":
    let fix = newFixture()
    defer: fix.cleanup()
    # Two shells sharing one HOME must not wedge on history.lock: each op
    # brackets open/close, so the second shell still reaches its prompt while
    # the first is alive, and both shells' commands persist.
    var sh1 = newShell(fix)
    require sh1.waitPrompt()
    var sh2 = newShell(fix)
    let secondOk = sh2.waitPrompt(timeout = 10.0)
    checkpoint "second shell prompts while first is alive (no lock wedge)"
    check secondOk
    if secondOk:
      discard sh1.runCmd("echo tab-one")
      discard sh2.runCmd("echo tab-two")
      sh1.close()
      sh2.close()

      var sh3 = newShell(fix)
      defer: sh3.close()
      require sh3.waitPrompt()
      let seg = sh3.runCmd("history")
      checkpoint "first shell command persisted"
      check "echo tab-one" in seg
      checkpoint "second shell command persisted"
      check "echo tab-two" in seg
    else:
      sh1.close()
      sh2.close()

  test "trash":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let note = fix.work / "note.txt"
    writeFile(note, "keep me")
    discard sh.runCmd("trash note.txt")
    # give the child a beat to move the file before we assert
    sleep(300)
    checkpoint "trash moves to ~/.Trash"
    check fileExists(fix.home / ".Trash" / "note.txt")
    checkpoint "trash removes from workdir"
    check not fileExists(note)

  test "policy":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let note = fix.work / "note.txt"
    writeFile(note, "keep me")
    let seg = sh.runCmd("rm note.txt")
    checkpoint "rm denied by default policy"
    check "command denied by policy" in seg
    checkpoint "file not removed"
    check fileExists(note)

  test "git-branch-switch":
    let repo = createTempDir("krantz-git-", "", "/tmp")
    defer: removeDir(repo)
    if not makeGitRepo(repo):
      fail()
    else:
      let fix = newFixture()
      defer: fix.cleanup()
      var sh = newShell(fix, cwd = repo)
      defer: sh.close()
      require sh.waitPrompt()
      checkpoint "initial prompt shows main"
      check "git:(main)" in sh.segment(0)
      let seg = sh.runCmd("git switch feature")
      checkpoint "prompt shows feature after switch"
      check "git:(feature)" in seg

  test "chat-offline":
    let fix = newFixture()
    defer: fix.cleanup()
    var sh = newShell(fix)
    defer: sh.close()
    require sh.waitPrompt()
    let base = sh.output.len
    sh.send("? hi" & CR, t = 0.3)
    discard sh.waitPrompt(base, timeout = 10.0)
    checkpoint "chat without provider is graceful"
    check "no LLM provider configured" in sh.segment(base)

  test "cli-help":
    let fix = newFixture()
    defer: fix.cleanup()
    let (output, code) = runCli(fix, ["help"])
    checkpoint "help exits 0"
    check code == 0
    checkpoint "help shows usage"
    check "Usage: krantz" in output

  test "cli-complete":
    let fix = newFixture()
    defer: fix.cleanup()
    let (output, code) = runCli(fix, ["complete", "src"])
    checkpoint "complete src -> src (no slash)"
    check code == 0 and output.splitLines().filterIt(it.len > 0) == @["src"]

  test "cli-config":
    let fix = newFixture()
    defer: fix.cleanup()
    let (_, codeInit) = runCli(fix, ["config", "init"])
    checkpoint "config init"
    check codeInit == 0
    let (outShow, codeShow) = runCli(fix, ["config", "show"])
    checkpoint "config show"
    check codeShow == 0 and "history" in outShow
    let (_, codeAdd) = runCli(fix, ["config", "deny", "add", "touch"])
    checkpoint "config deny add"
    check codeAdd == 0
    let (outList, codeList) = runCli(fix, ["config", "deny", "list"])
    checkpoint "config deny add+list"
    check codeList == 0 and "touch" in outList

  test "cli-llm":
    let fix = newFixture()
    defer: fix.cleanup()
    let (_, code) = runCli(fix, ["llm", "list"])
    checkpoint "llm list exits 0"
    check code == 0
