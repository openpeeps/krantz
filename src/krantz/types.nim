import std/[tables]
import boogie/stores/rdbms

type
  ColorKind* = enum
    ckNone = -1
    ckBlack
    ckRed
    ckGreen
    ckYellow
    ckBlue
    ckMagenta
    ckCyan
    ckWhite

  PolicyConfig* = object
    deny*: seq[string]

  HistoryConfig* = object
    maxSize*: int

  PromptConfig* = object
    user*: bool
    host*: bool
    git*: bool
    cwdShort*: bool

  BanksyConfig* = object
    policy*: PolicyConfig
    history*: HistoryConfig
    prompt*: PromptConfig

  PolicyResultKind* = enum
    prAllowed
    prDenied

  PolicyResult* = object
    kind*: PolicyResultKind
    message*: string

  PolicyEngine* = ref object
    denyCommands*: seq[string]

  QuoteKind* = enum
    qkNone
    qkSingle
    qkDouble

  TokenKind* = enum
    tokWord
    tokPipe
    tokRedirOut
    tokRedirOutApp
    tokRedirIn
    tokFdDup
    tokBothOut
    tokBackground
    tokSemicolon
    tokAnd
    tokOr
    tokEOF

  Token* = object
    kind*: TokenKind
    value*: string
    quoteKind*: QuoteKind

  RedirectionKind* = enum
    rkInput
    rkOutput
    rkOutputAppend
    rkFdDup

  Redirection* = object
    kind*: RedirectionKind
    fd*: int
    target*: string

  SimpleCommand* = ref object
    args*: seq[string]
    argQuotes*: seq[QuoteKind]
    redirects*: seq[Redirection]
    envVars*: seq[(string, string)]

  Pipeline* = ref object
    commands*: seq[SimpleCommand]
    background*: bool

  PipelineSep* = enum
    psSequential
    psAndThen
    psOrElse

  ParsedLine* = object
    pipelines*: seq[Pipeline]
    separators*: seq[PipelineSep]

  ShellState* = ref object
    config*: BanksyConfig
    policy*: PolicyEngine
    store*: Store
    lastExitCode*: int
    shouldExit*: bool
    prevDir*: string
    lastCwd*: string
    cachedBranch*: string
    vars*: TableRef[string, string]
