# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, options, posix, strutils, tables, termios, times]
import boogie/stores/rdbms

import ./config

proc llmStorePath*(): string =
  configDir() / "llm"

proc openLLMStore*(): Store =
  createDir(configDir())
  template openOnce() =
    let store = newStore(llmStorePath(), smDisk, enableWal = true,
                         checkpointEveryOps = 500'u32,
                         walFlushEveryOps = 1'u32)
    let tbl = newTable("providers", "id",
      columns = [newColumn("id", dtInt, false),
                 newColumn("name", dtText, false),
                 newColumn("address", dtText, false),
                 newColumn("key", dtText, false),
                 newColumn("model", dtText, false),
                 newColumn("ts", dtInt, false)],
      primaryKeyMode = pkmSerial)
    store.createTableIfNotExist(tbl)
    let settings = newTable("settings", "id",
      columns = [newColumn("id", dtInt, false),
                 newColumn("key", dtText, false),
                 newColumn("value", dtText, false)],
      primaryKeyMode = pkmSerial)
    store.createTableIfNotExist(settings)
    result = store
  try:
    openOnce()
  except CatchableError as e:
    # e.g. the WAL/snapshot was written by an incompatible boogie version
    stderr.writeLine("krantz: LLM store unavailable (", e.msg, ") — recreating")
    for ext in [".wal", ".db"]:
      let f = llmStorePath().changeFileExt(ext)
      if fileExists(f):
        try: removeFile(f)
        except OSError: discard
    try:
      openOnce()
    except CatchableError as e2:
      stderr.writeLine("krantz: LLM store still unavailable (", e2.msg, ")")
      result = nil

const defaultProviderKey = "default_provider"

proc getSetting(store: Store, key: string): string =
  let tbl = store.getTable("settings").get()
  for pk, row in tbl.allRows():
    if row["key"].strVal == key:
      result = row["value"].strVal
      break

proc setSetting(store: Store, key, value: string) =
  let tbl = store.getTable("settings").get()
  var toDelete: seq[string]
  for pk, row in tbl.allRows():
    if row["key"].strVal == key:
      toDelete.add(pk)
  for pk in toDelete:
    discard store.deleteRow("settings", pk)
  discard insertRow(store, "settings", row({
    "key": newTextValue(key),
    "value": newTextValue(value)
  }))

proc getDefaultProvider*(store: Store): string =
  result = getSetting(store, defaultProviderKey)

proc saveProvider*(store: Store, name, address, key, model: string) =
  let tbl = store.getTable("providers").get()
  var toDelete: seq[string]
  for pk, row in tbl.allRows():
    if row["name"].strVal == name:
      toDelete.add(pk)
  for pk in toDelete:
    discard store.deleteRow("providers", pk)
  discard store.insertRow("providers", row({
    "name": newTextValue(name),
    "address": newTextValue(address),
    "key": newTextValue(key),
    "model": newTextValue(model),
    "ts": newIntValue(epochTime().int64)
  }))
  if getSetting(store, defaultProviderKey).len == 0:
    setSetting(store, defaultProviderKey, name)

type
  ProviderInfo* = object
    name*, address*, key*, model*: string

proc listProviders*(store: Store): seq[ProviderInfo] =
  let tbl = store.getTable("providers").get()
  for pk, row in tbl.allRows():
    result.add(ProviderInfo(
      name: row["name"].strVal,
      address: row["address"].strVal,
      key: row["key"].strVal,
      model: row["model"].strVal
    ))

proc setDefaultProvider*(store: Store, name: string): bool =
  for p in listProviders(store):
    if p.name == name:
      setSetting(store, defaultProviderKey, name)
      result = true
      return
  result = false

proc readValue*(prompt: string): string =
  stdout.write(prompt)
  stdout.flushFile()
  try:
    result = stdin.readLine().strip()
  except EOFError:
    result = ""

proc readSecret*(prompt: string): string =
  stdout.write(prompt)
  stdout.flushFile()
  let fd = getFileHandle(stdin)
  let isTty = posix.isatty(0) != 0
  var old, raw: Termios
  var changed = false
  if isTty and fd.tcGetAttr(old.addr) != -1:
    raw = old
    raw.c_lflag = raw.c_lflag and not Cflag(ECHO)
    if fd.tcSetAttr(TCSADRAIN, raw.addr) == 0:
      changed = true
  try:
    result = stdin.readLine().strip()
  except EOFError:
    result = ""
  if changed:
    discard fd.tcSetAttr(TCSADRAIN, old.addr)
  echo ""

proc listProvidersCli*() =
  let store = openLLMStore()
  if store.isNil:
    stderr.writeLine "krantz: LLM store unavailable"
    quit(1)
  let defaultName = getDefaultProvider(store)
  let providers = listProviders(store)
  if providers.len == 0:
    echo "no LLM providers configured"
    return
  echo "LLM providers:"
  for p in providers:
    let marker = if p.name == defaultName: " (default)" else: ""
    echo "  ", p.name, " — ", p.model, marker
  echo ""
  echo "switch default with: krantz llm use <provider>"

proc useProviderCli*(name: string) =
  let store = openLLMStore()
  if store.isNil:
    stderr.writeLine "krantz: LLM store unavailable"
    quit(1)
  if not setDefaultProvider(store, name):
    stderr.writeLine "krantz: provider not found: ", name
    quit(1)
  store.checkpoint()
  echo "default LLM provider: ", name
