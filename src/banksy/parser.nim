import std/strutils

import ./types

proc lexLine*(input: string): seq[Token] =
  var pos = 0
  while pos < input.len:
    var ch = input[pos]

    if ch in {' ', '\t'}:
      inc pos; continue

    if ch == '#':
      break

    if ch == '\'':
      inc pos
      var val = ""
      while pos < input.len and input[pos] != '\'':
        val.add(input[pos]); inc pos
      if pos < input.len: inc pos  # closing '
      result.add(Token(kind: tokWord, value: val))
      continue

    if ch == '"':
      inc pos
      var val = ""
      while pos < input.len and input[pos] != '"':
        if input[pos] == '\\' and pos + 1 < input.len:
          inc pos
          case input[pos]
          of 'n': val.add('\n')
          of 't': val.add('\t')
          of '\\': val.add('\\')
          of '"': val.add('"')
          of '$': val.add('$')
          else: val.add(input[pos])
        else:
          val.add(input[pos])
        inc pos
      if pos < input.len: inc pos  # closing "
      result.add(Token(kind: tokWord, value: val))
      continue

    if ch == '\\' and pos + 1 < input.len:
      inc pos
      result.add(Token(kind: tokWord, value: $input[pos]))
      inc pos; continue

    if pos + 1 < input.len:
      if ch == '&' and input[pos+1] == '&':
        result.add(Token(kind: tokAnd))
        pos += 2
        continue
      if ch == '|' and input[pos+1] == '|':
        result.add(Token(kind: tokOr))
        pos += 2
        continue
      if ch == '>' and input[pos+1] == '>':
        result.add(Token(kind: tokRedirOutApp))
        pos += 2; continue
      if ch == '>' and input[pos+1] == '&':
        result.add(Token(kind: tokFdDup, value: ">&"))
        pos += 2; continue
      if ch == '<' and input[pos+1] == '&':
        result.add(Token(kind: tokFdDup, value: "<&"))
        pos += 2; continue
      if ch == '&' and input[pos+1] == '>':
        result.add(Token(kind: tokBothOut))
        pos += 2; continue

    case ch
    of ';':
      result.add(Token(kind: tokSemicolon))
      inc pos
    of '|':
      result.add(Token(kind: tokPipe))
      inc pos
    of '>':
      result.add(Token(kind: tokRedirOut))
      inc pos
    of '<':
      result.add(Token(kind: tokRedirIn))
      inc pos
    of '&':
      result.add(Token(kind: tokBackground))
      inc pos
    else:
      var val = ""
      while pos < input.len:
        ch = input[pos]
        if ch in {' ', '\t', '|', ';', '&', '>', '<', '#', '\'', '"'}:
          break
        if ch == '\\' and pos + 1 < input.len:
          inc pos
          val.add(input[pos])
          inc pos
          continue
        val.add(ch)
        inc pos
      if val.len > 0:
        result.add(Token(kind: tokWord, value: val))

  result.add(Token(kind: tokEOF))

proc parseRedirectionTarget(tokens: seq[Token], pos: var int): Redirection =
  if pos < tokens.len and tokens[pos].kind == tokWord:
    result.target = tokens[pos].value
    inc pos
  else:
    result.target = ""

proc parseSimpleCommand(tokens: seq[Token], pos: var int): SimpleCommand =
  result = SimpleCommand(args: @[], redirects: @[])

  while pos < tokens.len:
    let tok = tokens[pos]
    case tok.kind
    of tokWord:
      if pos + 1 < tokens.len and tokens[pos+1].kind in {tokRedirOut, tokRedirOutApp, tokRedirIn}:
        if tok.value.len > 0 and tok.value.allCharsInSet(Digits):
          let fd = parseInt(tok.value)
          inc pos
          let opKind = tokens[pos].kind
          inc pos
          var redir: Redirection
          case opKind
          of tokRedirOut: redir = Redirection(kind: rkOutput, fd: fd)
          of tokRedirOutApp: redir = Redirection(kind: rkOutputAppend, fd: fd)
          of tokRedirIn: redir = Redirection(kind: rkInput, fd: fd)
          else: discard
          redir.target = parseRedirectionTarget(tokens, pos).target
          result.redirects.add(redir)
        else:
          result.args.add(tok.value)
          inc pos
      elif pos + 1 < tokens.len and tokens[pos+1].kind == tokFdDup:
        if tok.value.len > 0 and tok.value.allCharsInSet(Digits):
          let fd = parseInt(tok.value)
          inc pos  # skip the numeric word
          inc pos  # skip tokFdDup
          var redir = Redirection(kind: rkFdDup, fd: fd)
          redir.target = parseRedirectionTarget(tokens, pos).target
          result.redirects.add(redir)
        else:
          result.args.add(tok.value)
          inc pos
      else:
        result.args.add(tok.value)
        inc pos

    of tokRedirOut:
      inc pos
      var redir = Redirection(kind: rkOutput, fd: 1)
      redir.target = parseRedirectionTarget(tokens, pos).target
      result.redirects.add(redir)

    of tokRedirOutApp:
      inc pos
      var redir = Redirection(kind: rkOutputAppend, fd: 1)
      redir.target = parseRedirectionTarget(tokens, pos).target
      result.redirects.add(redir)

    of tokRedirIn:
      inc pos
      var redir = Redirection(kind: rkInput, fd: 0)
      redir.target = parseRedirectionTarget(tokens, pos).target
      result.redirects.add(redir)

    of tokBothOut:
      inc pos
      let target = parseRedirectionTarget(tokens, pos).target
      result.redirects.add(Redirection(kind: rkOutput, fd: 1, target: target))
      result.redirects.add(Redirection(kind: rkOutput, fd: 2, target: target))

    of tokFdDup:
      let dir = tok.value  # ">&" or "<&"
      inc pos
      var redir = Redirection(kind: rkFdDup)
      if dir == ">&":
        redir.fd = 1
      else:
        redir.fd = 0
      redir.target = parseRedirectionTarget(tokens, pos).target
      result.redirects.add(redir)

    else:
      break

proc parsePipeline(tokens: seq[Token], pos: var int): Pipeline =
  result = Pipeline(commands: @[], background: false)

  while pos < tokens.len:
    let cmd = parseSimpleCommand(tokens, pos)
    if cmd.args.len > 0 or cmd.redirects.len > 0:
      result.commands.add(cmd)

    if pos < tokens.len and tokens[pos].kind == tokPipe:
      inc pos
    else:
      break

  if pos < tokens.len and tokens[pos].kind == tokBackground:
    result.background = true
    inc pos

proc parseTokens*(tokens: seq[Token]): ParsedLine =
  result = ParsedLine(pipelines: @[], separators: @[])
  var pos = 0

  while pos < tokens.len and tokens[pos].kind != tokEOF:
    let pipe = parsePipeline(tokens, pos)
    if pipe.commands.len > 0:
      result.pipelines.add(pipe)

    if pos < tokens.len and tokens[pos].kind in {tokSemicolon, tokAnd, tokOr}:
      case tokens[pos].kind
      of tokSemicolon:
        result.separators.add(psSequential)
        inc pos
      of tokAnd:
        result.separators.add(psAndThen)
        inc pos
      of tokOr:
        result.separators.add(psOrElse)
        inc pos
      else: discard

proc parseLine*(input: string): ParsedLine =
  let tokens = lexLine(input)
  result = parseTokens(tokens)
