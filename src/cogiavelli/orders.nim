## One grammar for parsing and printing Cogiavelli orders, plus the legal
## order set a seat is handed in its prompt.
##
##   A VER H              A VER - MAN            A BAR - PAL VIA CONVOY
##   F VEN S A PAD - FER  F VEN S A PAD          F LAD C A BAR - RAG
##
## Canonical notation only: A/F unit kind, three-letter province codes,
## H / - / S / C, and VIA CONVOY. An order that does not fit comes back
## `illegal` with a one-word `why`.

import std/strutils, types

type
  Board* = object
    units*: seq[Unit]
    at*: array[NumAreas, int]   ## unit index standing in each area, -1 empty

proc newBoard*(units: seq[Unit]): Board =
  result.units = units
  for index in 0 ..< NumAreas:
    result.at[index] = -1
  for index, unit in units:
    result.at[unit.province] = index

proc unitIndexAt*(board: Board, province: int): int =
  if province < 0 or province >= NumAreas: -1 else: board.at[province]

proc hasUnit*(board: Board, province: int): bool =
  board.unitIndexAt(province) >= 0

proc unitAt*(board: Board, province: int): Unit =
  board.units[board.at[province]]

proc kindLetter*(kind: UnitKind): string =
  if kind == ukFleet: "F" else: "A"

proc unitText*(unit: Unit): string =
  kindLetter(unit.kind) & " " & Provinces[unit.province].code

proc blankOrder*(power, province: int): Order =
  Order(power: power, unit: province, kind: okHold, target: -1, auxFrom: -1,
    auxTo: -1)

proc formatOrder*(order: Order, kind: UnitKind,
    auxKind: UnitKind = ukArmy): string =
  ## Canonical notation for one order.
  let head = kindLetter(kind) & " " & Provinces[order.unit].code
  let aux = kindLetter(auxKind) & " "
  case order.kind
  of okHold:
    head & " H"
  of okMove:
    head & " - " & Provinces[order.target].code &
      (if order.viaConvoy: " VIA CONVOY" else: "")
  of okSupportHold:
    head & " S " & aux & Provinces[order.auxFrom].code
  of okSupportMove:
    head & " S " & aux & Provinces[order.auxFrom].code & " - " &
      Provinces[order.auxTo].code
  of okConvoy:
    head & " C " & aux & Provinces[order.auxFrom].code & " - " &
      Provinces[order.auxTo].code

proc formatOrder*(board: Board, order: Order): string =
  let index = board.unitIndexAt(order.unit)
  let kind = if index >= 0: board.units[index].kind else: ukArmy
  var auxKind = ukArmy
  let auxIndex = board.unitIndexAt(order.auxFrom)
  if auxIndex >= 0:
    auxKind = board.units[auxIndex].kind
  formatOrder(order, kind, auxKind)

proc normalise(raw: string): seq[string] =
  raw.strip().toUpperAscii().splitWhitespace()

proc kindFromToken(token: string): int =
  ## 0 = army, 1 = fleet, -1 = not a unit token.
  case token
  of "A": 0
  of "F": 1
  else: -1

proc parseUnitRef*(board: Board, text: string): int =
  ## `"A ROM"` -> the province of the unit standing in Rome, or -1 when
  ## there is none, the kind letter disagrees, or the reference is not a
  ## canonical `<A|F> <CODE>` unit reference.
  let tokens = normalise(text)
  if tokens.len != 2:
    return -1
  let wanted = kindFromToken(tokens[0])
  if wanted < 0:
    return -1
  let province = provinceByCode(tokens[1])
  if province < 0 or not board.hasUnit(province):
    return -1
  let kind = board.unitAt(province).kind
  if (wanted == 1) != (kind == ukFleet):
    return -1
  province

proc parseOrder*(board: Board, power: int, raw: string): Order =
  ## Grammar only: the result carries `illegal` with `why` for anything
  ## that does not parse or names a unit this power does not own. Rule
  ## legality (adjacency, convoy paths, unit kinds) is checked in step 7.
  result = blankOrder(power, -1)
  result.raw = raw.strip()
  proc bad(why: string): Order =
    var order = blankOrder(power, -1)
    order.raw = raw.strip()
    order.illegal = true
    order.why = why
    order
  let tokens = normalise(raw)
  if tokens.len < 3:
    return bad("parse")
  if kindFromToken(tokens[0]) < 0:
    return bad("parse")
  let wantFleet = kindFromToken(tokens[0]) == 1
  let origin = provinceByCode(tokens[1])
  if origin < 0:
    return bad("parse")
  result.unit = origin
  let index = board.unitIndexAt(origin)
  if index < 0 or board.units[index].power != power:
    var order = bad("notowned")
    order.unit = origin
    return order
  if (board.units[index].kind == ukFleet) != wantFleet:
    var order = bad("wrongunit")
    order.unit = origin
    return order

  proc badAt(why: string): Order =
    var order = blankOrder(power, origin)
    order.raw = raw.strip()
    order.illegal = true
    order.why = why
    order

  case tokens[2]
  of "H":
    if tokens.len != 3:
      return badAt("parse")
    result.kind = okHold
  of "-":
    if tokens.len != 4 and tokens.len != 6:
      return badAt("parse")
    let dest = provinceByCode(tokens[3])
    if dest < 0:
      return badAt("parse")
    result.kind = okMove
    result.target = dest
    if tokens.len == 6:
      if tokens[4] == "VIA" and tokens[5] == "CONVOY":
        result.viaConvoy = true
      else:
        return badAt("parse")
  of "S":
    if tokens.len != 5 and tokens.len != 7:
      return badAt("parse")
    let auxKind = kindFromToken(tokens[3])
    if auxKind < 0:
      return badAt("parse")
    let from0 = provinceByCode(tokens[4])
    if from0 < 0:
      return badAt("parse")
    if board.hasUnit(from0) and
        (board.unitAt(from0).kind == ukFleet) != (auxKind == 1):
      return badAt("wrongunit")
    result.auxFrom = from0
    if tokens.len == 5:
      result.kind = okSupportHold
      return
    if tokens[5] != "-":
      return badAt("parse")
    let to0 = provinceByCode(tokens[6])
    if to0 < 0:
      return badAt("parse")
    result.kind = okSupportMove
    result.auxTo = to0
  of "C":
    if tokens.len != 7:
      return badAt("parse")
    if kindFromToken(tokens[3]) != 0:
      return badAt("wrongunit")
    let from0 = provinceByCode(tokens[4])
    if from0 < 0:
      return badAt("parse")
    if tokens[5] != "-":
      return badAt("parse")
    let to0 = provinceByCode(tokens[6])
    if to0 < 0:
      return badAt("parse")
    result.kind = okConvoy
    result.auxFrom = from0
    result.auxTo = to0
  else:
    return badAt("parse")

proc checkLegality*(board: Board, order: var Order) =
  ## Step 7's rule check. Anything illegal becomes a hold for that unit,
  ## with the reason recorded.
  if order.illegal:
    return
  let index = board.unitIndexAt(order.unit)
  if index < 0 or board.units[index].power != order.power:
    order.illegal = true
    order.why = "notowned"
    return
  let unit = board.units[index]
  let fleet = unit.kind == ukFleet
  case order.kind
  of okHold:
    discard
  of okMove:
    if order.target == order.unit:
      order.illegal = true
      order.why = "nonadjacent"
      return
    if fleet:
      if order.viaConvoy or not isCoastal(order.target) and
          not isSea(order.target):
        order.illegal = true
        order.why = "wrongunit"
        return
      if not isAdjacent(order.unit, order.target, true):
        order.illegal = true
        order.why = "nonadjacent"
      return
    ## An army never enters a sea.
    if isSea(order.target):
      order.illegal = true
      order.why = "wrongunit"
      return
    if order.viaConvoy or not isAdjacent(order.unit, order.target, false):
      if order.target notin convoyReachable(order.unit):
        order.illegal = true
        order.why = (if order.viaConvoy: "noconvoy" else: "nonadjacent")
  of okSupportHold:
    if not board.hasUnit(order.auxFrom):
      order.illegal = true
      order.why = "notthere"
      return
    if not isAdjacent(order.unit, order.auxFrom, fleet):
      order.illegal = true
      order.why = "nonadjacent"
  of okSupportMove:
    if not board.hasUnit(order.auxFrom):
      order.illegal = true
      order.why = "notthere"
      return
    if not isAdjacent(order.unit, order.auxTo, fleet):
      order.illegal = true
      order.why = "nonadjacent"
  of okConvoy:
    if not fleet:
      order.illegal = true
      order.why = "wrongunit"
      return
    if not isSea(order.unit):
      order.illegal = true
      order.why = "wrongunit"
      return
    if not board.hasUnit(order.auxFrom):
      order.illegal = true
      order.why = "notthere"
      return
    if board.unitAt(order.auxFrom).kind == ukFleet:
      order.illegal = true
      order.why = "wrongunit"
      return
    if not isCoastal(order.auxFrom) or not isCoastal(order.auxTo):
      order.illegal = true
      order.why = "nonadjacent"

proc legalOrders*(board: Board, province: int): seq[string] =
  ## Enumerate the canonical choices using the same rule check as dispatch.
  ## Support and convoy can be submitted even if the other unit won't match.
  if not board.hasUnit(province):
    return
  let unit = board.unitAt(province)
  template offer(action: OrderKind, dest = -1, source = -1, into = -1, convoy = false) =
    var order = Order(power: unit.power, unit: province, kind: action,
      target: dest, auxFrom: source, auxTo: into, viaConvoy: convoy)
    checkLegality(board, order)
    if not order.illegal:
      result.add(formatOrder(board, order))

  offer(okHold)
  let fleet = unit.kind == ukFleet
  let neighbours = if fleet: FleetAdj[province] else: ArmyAdj[province]
  for dest in neighbours:
    offer(okMove, dest)
  if not fleet and isCoastal(province):
    for dest in convoyReachable(province):
      offer(okMove, dest, convoy = true)

  for other in board.units:
    offer(okSupportHold, source = other.province)
    for dest in neighbours:
      offer(okSupportMove, source = other.province, into = dest)
    if fleet and isSea(province) and other.kind == ukArmy and isCoastal(other.province):
      for dest in 0 ..< NumLand:
        offer(okConvoy, source = other.province, into = dest)
