# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, options, tables, times]
import boogie/stores/rdbms

import ./types

proc openHistoryStore*(state: var ShellState) =
  if not state.store.isNil: return
  let histPath = getHomeDir() / ".krantz" / "history"
  createDir(getHomeDir() / ".krantz")
  template openOnce() =
    let store = newStore(histPath, smDisk, enableWal = true,
                         checkpointEveryOps = 500'u32,
                         walFlushEveryOps = 1'u32)
    let tbl = newTable("history", "id",
      columns = [newColumn("id", dtInt, false),
                 newColumn("cmd", dtText, false),
                 newColumn("ts", dtInt, false)],
      primaryKeyMode = pkmSerial)
    store.createTableIfNotExist(tbl)
    state.store = store
  try:
    openOnce()
  except CatchableError as e:
    # e.g. the WAL/snapshot was written by an incompatible boogie version
    stderr.writeLine("krantz: history store unavailable (", e.msg, ") — recreating")
    for ext in [".wal", ".db"]:
      let f = histPath.changeFileExt(ext)
      if fileExists(f):
        try: removeFile(f)
        except OSError: discard
    try:
      openOnce()
    except CatchableError as e2:
      stderr.writeLine("krantz: history store still unavailable (", e2.msg, ") — continuing without history")
      state.store = nil

proc ensureHistoryStore*(state: var ShellState) =
  ## Opens the history store on first use, so a fresh instance doesn't pay
  ## the store/WAL load cost until history is actually needed.
  if state.store.isNil:
    openHistoryStore(state)

proc addHistory*(state: var ShellState, cmd: string) =
  ensureHistoryStore(state)
  let maxSize = if state.config.history.maxSize > 0: state.config.history.maxSize else: 1000
  discard state.store.insertRow("history", row({
    "cmd": newTextValue(cmd),
    "ts": newIntValue(epochTime().int64)
  }))
  let tbl = state.store.getTable("history").get()
  var count = 0
  var toDelete: seq[string]
  for pk, _ in tbl.allRows():
    inc count
    if count > maxSize:
      toDelete.add(pk)
  for pk in toDelete:
    discard state.store.deleteRow("history", pk)

proc loadAllHistory*(state: ShellState): seq[string] =
  let tbl = state.store.getTable("history").get()
  for pk, row in tbl.allRows():
    result.add(row["cmd"].strVal)

proc getHistory*(state: var ShellState, n: int = 20): seq[(string, string, int64)] =
  ensureHistoryStore(state)
  let tbl = state.store.getTable("history").get()
  var entries: seq[(string, string, int64)]
  for pk, row in tbl.allRows():
    entries.add((pk, row["cmd"].strVal, row["ts"].intVal))
  if entries.len > n:
    entries = entries[entries.len - n .. ^1]
  entries
