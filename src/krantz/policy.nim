# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[strutils, strformat]

import ./types

proc newPolicyEngine*(config: KrantzConfig): PolicyEngine =
  result = PolicyEngine(denyCommands: @[])
  if config.policy.deny.len > 0:
    for cmd in config.policy.deny:
      result.denyCommands.add(cmd.toLowerAscii())

proc check*(engine: PolicyEngine, cmdName: string): PolicyResult =
  let name = cmdName.strip().toLowerAscii()
  if name.len == 0:
    return PolicyResult(kind: prAllowed)

  for denied in engine.denyCommands:
    if name == denied:
      return PolicyResult(
        kind: prDenied,
        message: fmt"command denied by policy: {denied}"
      )

  PolicyResult(kind: prAllowed)
