# A fast ZSH alternative written in Nim
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/georgelemon/krantz

import std/[os, options, tables, times]
import boogie/stores/rdbms

import ./types

proc openHistoryStore*(state: var ShellState) =
  let histPath = getHomeDir() / ".krantz" / "history"
  createDir(getHomeDir() / ".krantz")
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

proc addHistory*(state: var ShellState, cmd: string) =
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

proc getHistory*(state: ShellState, n: int = 20): seq[(string, string, int64)] =
  let tbl = state.store.getTable("history").get()
  var entries: seq[(string, string, int64)]
  for pk, row in tbl.allRows():
    entries.add((pk, row["cmd"].strVal, row["ts"].intVal))
  if entries.len > n:
    entries = entries[entries.len - n .. ^1]
  entries
