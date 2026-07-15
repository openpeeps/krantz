# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[algorithm, os, strutils, sequtils, posix, tables]
import ./types

proc tildeExpand*(word: string): string =
  if word.len == 0 or word[0] != '~': return word
  try:
    result = os.expandTilde(word)
  except OSError:
    result = word

proc expandVarExpr(expr: string; vars: TableRef[string, string]): string =
  let colon = expr.find(':')
  let varName = if colon >= 0: expr[0..colon-1] else: expr

  let value = if vars != nil and vars.hasKey(varName): vars[varName] else: getEnv(varName)

  if colon < 0:
    return value

  let op = expr[colon+1]
  let rest = if colon + 2 < expr.len: expr[colon+2..^1] else: ""
  let isSet = value.len > 0

  case op
  of '-': return if isSet: value else: rest
  of '=':
    if not isSet:
      putEnv(varName, rest)
      if vars != nil: vars[varName] = rest
      return rest
    return value
  of '+': return if isSet: rest else: ""
  of '?':
    if not isSet:
      stderr.writeLine("krantz: " & varName & ": " & rest)
    return value
  else: return value

proc expandEnv*(word: string; vars: TableRef[string, string]): string =
  var i = 0
  while i < word.len:
    if word[i] == '$' and i + 1 < word.len:
      if word[i+1] == '$':
        result.add($posix.getpid())
        i += 2
      elif word[i+1] == '{':
        let closingBrace = word.find('}', i)
        if closingBrace > 0:
          result.add(expandVarExpr(word[i+2..closingBrace-1], vars))
          i = closingBrace + 1
        else:
          result.add(word[i]); inc i
      else:
        var j = i + 1
        while j < word.len and (word[j].isAlphaNumeric or word[j] == '_'):
          inc j
        if j > i + 1:
          var varValue = ""
          if vars != nil and vars.hasKey(word[i+1..j-1]):
            varValue = vars[word[i+1..j-1]]
          else:
            varValue = getEnv(word[i+1..j-1], "")
          result.add(varValue)
          i = j
        else:
          result.add(word[i]); inc i
    else:
      result.add(word[i]); inc i

proc findMatchingParen(s: string, start: int): int =
  var depth = 1
  var i = start + 2
  var inSingle = false
  var inDouble = false
  while i < s.len:
    if inSingle:
      if s[i] == '\'': inSingle = false
    elif inDouble:
      if s[i] == '"': inDouble = false
      elif s[i] == '\\': inc i
    else:
      case s[i]
      of '\'': inSingle = true
      of '"': inDouble = true
      of '(': inc depth
      of ')':
        dec depth
        if depth == 0: return i
      of '\\': inc i
      else: discard
    inc i
  return -1

proc findMatchingBacktick(s: string, start: int): int =
  var i = start + 1
  while i < s.len:
    if s[i] == '\\': inc i
    elif s[i] == '`': return i
    inc i
  return -1

proc executeAndCapture(cmd: string): string =
  var pipefds: array[2, cint]
  if posix.pipe(pipefds) != 0: return ""

  let pid = fork()
  if pid < 0:
    discard close(pipefds[0]); discard close(pipefds[1])
    return ""

  if pid == 0:
    discard close(pipefds[0])
    discard dup2(pipefds[1], 1)
    discard close(pipefds[1])
    discard execlp("/bin/sh".cstring, "sh".cstring, "-c".cstring, cmd.cstring, nil)
    quit(1)

  discard close(pipefds[1])
  var buf: array[4096, char]
  while true:
    let n = read(pipefds[0], buf[0].addr, 4096)
    if n <= 0: break
    for j in 0..<int(n):
      result.add(buf[j])
  discard close(pipefds[0])
  var status: cint = 0
  discard waitpid(pid, status, 0)

  while result.len > 0 and result[^1] == '\n':
    result.setLen(result.len - 1)

proc expandCommandSubst*(word: string): string =
  var i = 0
  while i < word.len:
    if word[i] == '$' and i + 1 < word.len and word[i+1] == '(':
      let closePos = findMatchingParen(word, i)
      if closePos > 0:
        let captured = executeAndCapture(word[i+2..closePos-1])
        result.add(captured)
        i = closePos + 1
        continue
    elif word[i] == '`':
      let closePos = findMatchingBacktick(word, i)
      if closePos > 0:
        let captured = executeAndCapture(word[i+1..closePos-1])
        result.add(captured)
        i = closePos + 1
        continue
    result.add(word[i]); inc i

proc globMatch(name: string, pattern: string): bool =
  var ni = 0; var pi = 0
  while ni < name.len and pi < pattern.len:
    case pattern[pi]
    of '*':
      inc pi
      if pi >= pattern.len: return true
      while ni < name.len:
        if globMatch(name[ni..^1], pattern[pi..^1]):
          return true
        inc ni
      return false
    of '?':
      inc ni; inc pi
    else:
      if pattern[pi] != name[ni]: return false
      inc ni; inc pi

  while pi < pattern.len and pattern[pi] == '*': inc pi
  return ni == name.len and pi == pattern.len

proc expandGlob*(word: string): seq[string] =
  if not word.contains({'*', '?', '['}):
    return @[word]

  let (dir, pattern) = if word.contains('/'):
    (word.parentDir(), word.extractFilename())
  else:
    (".", word)

  result = @[]
  let absDir = tildeExpand(dir)
  try:
    for kind, path in walkDir(absDir):
      let name = path.extractFilename()
      if globMatch(name, pattern):
        if dir == ".":
          result.add(name)
        else:
          result.add(dir / name)
  except OSError:
    discard

  if result.len == 0:
    result = @[word]
  elif result.len > 1:
    sort(result, cmp[string])

proc isValidVarName(s: string): bool =
  if s.len == 0: return false
  if s[0] != '_' and not s[0].isAlphaAscii: return false
  for i in 1..<s.len:
    if s[i] != '_' and not s[i].isAlphaNumeric:
      return false
  true

proc isAssignment(word: string; quoteKind: QuoteKind): bool =
  if quoteKind != qkNone: return false
  let eq = word.find('=')
  if eq <= 0: return false
  isValidVarName(word[0..eq-1])

proc expandWord*(word: string; quoteKind: QuoteKind; vars: TableRef[string, string]): seq[string] =
  var w = word

  if quoteKind == qkNone and w.len > 0 and w[0] == '~':
    w = tildeExpand(w)

  if quoteKind != qkSingle and (w.contains('$') or w.contains('`') or w.find("$(") >= 0):
    w = expandCommandSubst(w)

  if quoteKind != qkSingle:
    w = expandEnv(w, vars)

  if quoteKind == qkNone and (w.contains('*') or w.contains('?') or w.contains('[')):
    result = expandGlob(w)
  else:
    result = @[w]

proc expandRedirTarget(target: string; vars: TableRef[string, string]): string =
  var t = target
  if t.len > 0 and t[0] == '~':
    t = tildeExpand(t)
  if t.contains('$') or t.contains('`') or t.find("$(") >= 0:
    t = expandCommandSubst(t)
  if t.contains('$'):
    t = expandEnv(t, vars)
  result = t

proc expandLine*(parsed: ParsedLine; vars: TableRef[string, string]): ParsedLine =
  result = parsed
  for pipe in result.pipelines.mitems:
    for cmd in pipe.commands:
      cmd.envVars = @[]

      var newArgs: seq[string] = @[]
      var newQuotes: seq[QuoteKind] = @[]
      for i, arg in cmd.args:
        let qk = if i < cmd.argQuotes.len: cmd.argQuotes[i] else: qkNone
        if isAssignment(arg, qk):
          let eq = arg.find('=')
          let varName = arg[0..eq-1]
          let varValueRaw = arg[eq+1..^1]
          var varValue = varValueRaw
          if varValue.contains('~') or varValue.contains('$') or varValue.contains('`') or varValue.find("$(") >= 0:
            varValue = expandCommandSubst(varValue)
            varValue = expandEnv(varValue, vars)
            if varValue.len > 0 and varValue[0] == '~':
              varValue = tildeExpand(varValue)
          if cmd.args.len == 1 and cmd.redirects.len == 0:
            if vars != nil: vars[varName] = varValue
          else:
            cmd.envVars.add((varName, varValue))
        else:
          let expanded = expandWord(arg, qk, vars)
          for e in expanded:
            newArgs.add(e)
            newQuotes.add(qk)
      cmd.args = newArgs
      cmd.argQuotes = newQuotes

      for redir in cmd.redirects.mitems:
        if redir.target.len > 0:
          redir.target = expandRedirTarget(redir.target, vars)
