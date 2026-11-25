import cogiavelli/prompts
## Bounded-orders / legality assertion on the scripted baselines, and the
## reply-parsing contract. The baselines are what every failed decision
## falls back to, so "always legal, always affordable, always terminates"
## is load-bearing, not decoration.

import
  std/[json, strutils, times, unicode],
  cogiavelli/[sim, llm]

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc newConfig(seed, years: int, press: bool): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.years = years
  result.press = press
  result.turnDelayMs = 0
  for index in 0 ..< 6:
    result.players.add(PlayerConfig(name: "P" & $index))
    result.tokens.add("t")
  result = sampleEpisode(result)

type Audit = object
  sim: Sim
  calls: int

proc play(config: GameConfig, kinds: seq[ScriptKind]): Audit =
  var sim = initSim(config)
  var client = LlmClient(transport: ltNone)
  let prompts = newSeq[string](6)
  var calls = 0
  var guard = 0
  while not sim.done and guard < 600:
    guard.inc
    let seats = sim.pendingSeats()
    let phase = sim.phase
    let decisions = decideAll(client, PromptSelection(), sim, phase, seats, prompts, kinds)
    calls.inc
    for index, seat in seats:
      if sim.done:
        break
      let decision = decisions[index]
      check(decision.scripted, "an explicit scripted seat always answers scripted")
      if phase == phOrders:
        check(decision.spend.len <= MaxSpendEntries,
          "no spend array exceeds six entries")
        var treasury = sim.treasury[sim.powerOf[seat]]
        for entry in decision.spend:
          check(entry.amount <= treasury,
            "every spend entry is affordable when it is written")
          treasury -= entry.amount
        sim.applyOrders(seat, decision.orders, decision.spend,
          decision.builds, decision.notes, true)
      else:
        sim.applyPress(seat, decision.broadcast, decision.letters,
          decision.pledges, decision.notes, true)
  Audit(sim: sim, calls: calls)

proc auditEpisode(audit: Audit) =
  let sim = audit.sim
  check(sim.done, "a scripted table always reaches an end condition")
  if sim.conqueror >= 0:
    ## The only other natural end: somebody actually took Italy. Assert the
    ## condition, not just the word.
    check(sim.reason == "conquest", "a named conqueror means a conquest")
    var holders = 0
    for power in 0 ..< Powers:
      if sim.citiesOf(power) > 0:
        holders.inc
    check(sim.citiesOf(sim.conqueror) >= VictoryCities or holders == 1,
      "a conquest is twelve cities or the last power owning any, got " &
        $sim.citiesOf(sim.conqueror) & " cities and " & $holders & " holders")
  else:
    check(sim.reason == "complete",
      "a scripted table with no conqueror plays every year out, got " &
        sim.reason)
    check(sim.yearsPlayed == sim.config.years,
      "and it played all of them, got " & $sim.yearsPlayed & "/" &
        $sim.config.years)
  for event in sim.events:
    case event.kind
    of evOrders:
      check(event.illegalRaw.len == 0,
        "every scripted order parses and is legal: " &
          event.illegalRaw.join(", "))
      var seen: seq[string]
      var destinations: seq[string]
      for order in event.orders:
        let parts = strutils.splitWhitespace(order)
        check(parts[1] notin seen, "every unit is ordered exactly once")
        seen.add(parts[1])
        if parts.len >= 4 and parts[2] == "-":
          check(parts[3] notin destinations,
            "no power ever stands itself off in " & Provinces[
              provinceByCode(parts[3])].code)
          destinations.add(parts[3])
    of evSpend:
      check(event.treasuryAfter >= 0, "no treasury ever goes negative")
    of evWinter:
      for build in event.builds:
        if build.applied:
          let parts = strutils.splitWhitespace(build.entry)
          check(parts.len == 2, "a build names a kind and a city")
          check(isCity(provinceByCode(parts[1])), "a build lands in a city")
          if parts[0] == "F":
            check(isCoastal(provinceByCode(parts[1])),
              "a fleet is only built in a coastal city")
      for treasury in event.treasury:
        check(treasury >= 0, "no treasury ever goes negative")
    else:
      discard
  for power in 0 ..< Powers:
    check(sim.treasury[power] >= 0, "no treasury ends negative")

block theCanonicalScriptedEpisodeCompletes:
  ## Checklist item 7, in the letter: an all-scripted episode runs to the
  ## natural end and `results.reason` is "complete". A single year puts
  ## conquest arithmetically out of reach — six powers start on three
  ## cities each and no power can reach twelve, or be the last holder, in
  ## three seasons — so this fixture can only end one way.
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(skCondottiere)
  let audit = play(newConfig(3, 1, true), kinds)
  check(audit.sim.resultsJson()["reason"].getStr() == "complete",
    "the canonical scripted episode reports reason=complete, got " &
      audit.sim.resultsJson()["reason"].getStr())
  auditEpisode(audit)

block condottiereSeeds:
  for seed in 1 .. 8:
    var kinds: seq[ScriptKind]
    for index in 0 ..< 6:
      kinds.add(skCondottiere)
    auditEpisode(play(newConfig(seed, 2, true), kinds))

block bankerSeeds:
  for seed in 1 .. 8:
    var kinds: seq[ScriptKind]
    for index in 0 ..< 6:
      kinds.add(skBanker)
    auditEpisode(play(newConfig(seed, 2, true), kinds))

block mixedTable:
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(if index < 3: skCondottiere else: skBanker)
  auditEpisode(play(newConfig(4, 2, true), kinds))

block aBaselineThatCannotBeatAWallIsNoBaseline:
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(if index == 5: skCondottiere else: skBanker)
  let audit = play(newConfig(5, 3, false), kinds)
  let sim = audit.sim
  let expander = sim.citiesOf(sim.powerOf[5])
  for seat in 0 ..< 5:
    check(expander > sim.cities(seat),
      "the condottiere must end with more cities than every banker: " &
        $expander & " vs " & $sim.cities(seat))

block explicitScriptedNeedsNoNetworkAndModelFailsWithoutTransport:
  let config = newConfig(2, 1, false)
  var sim = initSim(config)
  ## A client with no transport at all: explicit scripted seats succeed without
  ## touching any network handle, while an unscripted model seat MUST fail
  ## explicitly with ModelDecisionError (no silent scripted fallback).
  var client = LlmClient(transport: ltNone)
  var scriptedKinds: seq[ScriptKind]
  for index in 0 ..< 6:
    scriptedKinds.add(if index mod 2 == 0: skCondottiere else: skBanker)
  let decisions = decideAll(client, PromptSelection(), sim, sim.phase, sim.pendingSeats(),
    newSeq[string](6), scriptedKinds)
  check(decisions.len == 6, "six explicit scripted decisions come back")
  for decision in decisions:
    check(decision.scripted, "every one of them is scripted")
    check(decision.orders.len > 0, "and carries real orders")

  var modelKinds = scriptedKinds
  modelKinds[0] = skNone
  var failed = false
  try:
    discard decideAll(client, PromptSelection(), sim, sim.phase, sim.pendingSeats(),
      newSeq[string](6), modelKinds)
  except ModelDecisionError as error:
    failed = error.seat == 0
  check(failed, "an unscripted model seat with no transport raises ModelDecisionError")

block finishesFast:
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(skCondottiere)
  let years = 4
  let started = epochTime()
  let audit = play(newConfig(6, years, true), kinds)
  let elapsed = (epochTime() - started) * 1000.0
  check(elapsed < float(years * 3 * 1000),
    "six scripted seats finish in under years x 3 x 1000 ms, took " &
      $elapsed.int & "ms")
  check(audit.calls > 0, "the batch loop ran")

# ---- reply parsing ----------------------------------------------------------

block replyParsing:
  var sim = initSim(newConfig(7, 2, true))
  let seat = 0
  let power = sim.powerOf[seat]
  let rival = PowerNames[(power + 1) mod Powers]

  ## Canonical PLAYER_SCRIPTED values only; aliases are rejected.
  check(parseScriptKind("") == skNone, "empty string means model seat")
  check(parseScriptKind("condottiere") == skCondottiere, "condottiere parses")
  check(parseScriptKind("banker") == skBanker, "banker parses")
  for alias in ["1", "true", "yes", "miser", "unknown"]:
    var bad = false
    try:
      discard parseScriptKind(alias)
    except CogiavelliError:
      bad = true
    check(bad, "scripted alias is rejected: " & alias)

  let fenced = "```json\n{\"broadcast\": \"peace\", \"notes\": \"x\"}\n```"
  let press = parsePress(sim, seat, extractJsonObject(fenced))
  check(press.broadcast == "peace", "standard outer markdown JSON fence is accepted")

  let bomFenced = "\xEF\xBB\xBF```json\n" &
    "{\"broadcast\": \"hold {VEN} and \\\"}\\\"\", \"notes\": \"plan {1}\"}\n```"
  let pressBom = parsePress(sim, seat, extractJsonObject(bomFenced))
  check(pressBom.broadcast == "hold {VEN} and \"}\"",
    "BOM and outer markdown fence are handled")
  check(pressBom.notes == "plan {1}", "notes parse cleanly")

  for badText in [
    "Here is my move.\n{\"orders\": [\"A VER H\"]}\nThat is all.",
    "```json\n{\"broadcast\": \"hi\"}\n```\nTrailing commentary.",
    "{\"orders\": [\"A VER H\"]",
    "no json here at all"
  ]:
    var rejected = false
    try:
      discard extractJsonObject(badText)
    except CogiavelliError:
      rejected = true
    check(rejected, "non-object / prose-wrapped reply is rejected: " & badText)

  for pad in 150 .. 165:
    let nonJson = "Refusal " & repeat("a", pad) & "é tail"
    var utf8Ok = false
    try:
      discard extractJsonObject(nonJson)
    except CogiavelliError as error:
      utf8Ok = validateUtf8(error.msg) == -1
    check(utf8Ok, "no-JSON error preview is cut on a rune boundary")

  for s in 0 ..< Seats:
    let pName = PowerNames[sim.powerOf[s]]
    let pressText = pressPrompt(sim, s, "")
    check("{\"to\":\"" & pName & "\"" notin pressText,
      "pressPrompt sample letter never targets the acting power itself")
    ## Every seat's ordersPrompt example must be legal for that seat!
    let ordersText = ordersPrompt(sim, s, "")
    let marker = "Reply with ONLY one JSON object:\n"
    let startIdx = ordersText.find(marker) + marker.len
    let endIdx = ordersText.find('\n', startIdx)
    let exampleLine = ordersText[startIdx ..< endIdx]
    let parsedExample = parseOrdersReply(sim, s, extractJsonObject(exampleLine))
    check(parsedExample.orders.len == 3,
      "ordersPrompt concrete example is valid and covers every unit for " & pName)

  ## Build a valid canonical orders list for `seat` to test strict validation.
  var validOrders = newJArray()
  for unit in sim.board.units:
    if unit.power == power:
      validOrders.add(%(unitText(unit) & " H"))
  let baseReply = %*{"orders": validOrders, "spend": [], "notes": "ok"}
  let okOrders = parseOrdersReply(sim, seat, baseReply)
  check(okOrders.orders.len == validOrders.len, "canonical orders reply parses")

  ## Optional fields (`spend`, `builds`, `notes`) may be omitted.
  let minimalOrders = parseOrdersReply(sim, seat, %*{"orders": validOrders})
  check(minimalOrders.orders.len == validOrders.len and minimalOrders.spend.len == 0,
    "omitted optional fields use documented empty defaults")

  proc expectOrdersError(payload: JsonNode, label: string) =
    var raised = false
    try:
      discard parseOrdersReply(sim, seat, payload)
    except CogiavelliError:
      raised = true
    check(raised, label)

  expectOrdersError(parseJson("""{"spend": []}"""),
    "a missing orders key is invalid")
  expectOrdersError(parseJson("""{"orders": []}"""),
    "omitting owned units is rejected rather than silently holding")
  expectOrdersError(%*{"orders": ["A NOT_A_PROVINCE - NOPE"]},
    "illegal order is rejected rather than silently holding")
  expectOrdersError(%*{"orders": validOrders, "spend": [
    {"action": "gift", "target": rival, "amount": "lots"}]},
    "a string amount is rejected")
  expectOrdersError(%*{"orders": validOrders, "spend": [
    {"action": "gift", "target": rival, "amount": 5.5}]},
    "a float amount is rejected")
  expectOrdersError(%*{"orders": validOrders, "spend": [
    {"action": "burn", "target": rival, "amount": 5}]},
    "an unknown spend action is rejected")
  expectOrdersError(%*{"orders": validOrders, "spend": [
    {"action": "gift", "target": "NOWHERE", "amount": 5}]},
    "an unresolvable target is rejected")
  expectOrdersError(%*{"orders": validOrders, "spend": [
    {"action": "assassinate", "target": rival, "amount": 2}]},
    "out-of-range assassinate amount is rejected rather than clamped")
  expectOrdersError(%*{"orders": validOrders, "spend": [
    {"action": "gift", "target": "THE " & rival, "amount": 5}]},
    "non-canonical power alias is rejected")

  ## Press strict validation
  proc expectPressError(payload: JsonNode, label: string) =
    var raised = false
    try:
      discard parsePress(sim, seat, payload)
    except CogiavelliError:
      raised = true
    check(raised, label)

  expectPressError(parseJson("""{"notes": "hi"}"""),
    "press with neither broadcast nor letters is invalid")
  expectPressError(%*{"broadcast": "", "letters": [{"to": "NOWHERE", "text": "hi"}]},
    "letter to unknown power is rejected")
  expectPressError(%*{"broadcast": "", "letters": [
    {"to": rival, "text": "a"}, {"to": rival, "text": "b"}]},
    "duplicate letter target is rejected")
  expectPressError(%*{"broadcast": "", "pledges": [{"kind": "truce", "to": rival}]},
    "unknown pledge kind is rejected")

echo "test_bot: ok"
