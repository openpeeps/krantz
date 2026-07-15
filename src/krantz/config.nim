# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, sequtils, strutils]
import openparser/yaml

import ./types

proc configDir*(): string =
  getHomeDir() / ".krantz"

proc configFile*(): string =
  configDir() / "config.yaml"

proc saveConfig*(cfg: KrantzConfig)

proc loadConfig*(): KrantzConfig =
  if not fileExists(configFile()):
    result = KrantzConfig(
      policy: PolicyConfig(deny: @["rm"]),
      history: HistoryConfig(maxSize: 1000),
      prompt: PromptConfig(user: false, host: false, git: true, cwdShort: false)
    )
    saveConfig(result)
    return

  let yamlContent = readFile(configFile())
  result = parseYAML(yamlContent, KrantzConfig)

proc saveConfig*(cfg: KrantzConfig) =
  ## Dump KrantzConfig to YAML
  # TODO use pkg/openparser/yaml (dump feature ~ need extra testing)
  createDir(configDir())
  var lines = @["policy:"]
  if cfg.policy.deny.len > 0:
    lines.add("  deny:")
    for cmd in cfg.policy.deny:
      lines.add("    - " & cmd)
  else:
    lines.add("  deny: []")
  let maxSize = if cfg.history.maxSize > 0: $cfg.history.maxSize else: "1000"
  lines.add("history:")
  lines.add("  maxSize: " & maxSize)
  lines.add("prompt:")
  lines.add("  user: " & $cfg.prompt.user)
  lines.add("  host: " & $cfg.prompt.host)
  lines.add("  git: " & $cfg.prompt.git)
  lines.add("  cwdShort: " & $cfg.prompt.cwdShort)
  writeFile(configFile(), lines.join("\n") & "\n")

proc initConfig*() =
  let cfg = KrantzConfig(
    policy: PolicyConfig(deny: @["rm"]),
    history: HistoryConfig(maxSize: 1000),
    prompt: PromptConfig(user: false, host: false, git: true, cwdShort: false)
  )
  saveConfig(cfg)
  echo "Created ", configFile()

proc printConfig*() =
  if fileExists(configFile()):
    echo readFile(configFile()).strip()
  else:
    echo "No config file at ", configFile()

proc configDenyList*() =
  let cfg = loadConfig()
  if cfg.policy.deny.len == 0:
    echo "No commands are denied"
  else:
    echo "Denied commands:"
    for cmd in cfg.policy.deny:
      echo "  - ", cmd

proc configDenyAdd*(cmd: string) =
  let name = cmd.toLowerAscii().strip()
  if name.len == 0:
    stderr.writeLine "error: command name required"
    quit(1)
  var cfg = loadConfig()
  for existing in cfg.policy.deny:
    if existing == name:
      echo "already denied: ", name
      return
  cfg.policy.deny.add(name)
  saveConfig(cfg)
  echo "added: ", name

proc configDenyRemove*(cmd: string) =
  let name = cmd.toLowerAscii().strip()
  if name.len == 0:
    stderr.writeLine "error: command name required"
    quit(1)
  var cfg = loadConfig()
  var found = false
  cfg.policy.deny.keepIf(proc(x: string): bool =
    if x == name:
      found = true
      return false
    return true
  )
  if found:
    saveConfig(cfg)
    echo "removed: ", name
  else:
    echo "not denied: ", name
