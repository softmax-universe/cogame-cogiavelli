## Cogiavelli game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - shared chrome
##   GET /client/assets/<name>       - sprites, the map and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (cogiavelli.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"power":...,"name":...}
##                   {"type":"state",...} after every event, redacted: the
##                   whole public board, the public city table, every
##                   treasury, this seat's own inbox and units, and nothing
##                   of any other power's pending orders or expenditure
##                   {"type":"final","scores":[...],...}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"condottiere"}

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  prompts,
  sim,
  training

const
  MaxPromptLen = 4000
  ReplayVersion = 1
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.
  PlayBudgetFraction* = 0.6
  ## The certifier pings /global AFTER the player pods start, so a short
  ## episode must keep answering for a while past its last artifact write.
  ShutdownGraceSeconds = 20.0

type
  GameState = object
    config: GameConfig
    selection: PromptSelection
    sim: Sim
    trajectory: DecisionTrajectory
    prompts: seq[string]
    scripted: seq[ScriptKind]
    promptDelivered: seq[bool]
    registrationErrors: seq[string]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the alias.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"cogiavelli"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  result = gs.sim.observationJson(slot)
  result["started"] = %gs.started

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get
  ## the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var powers = newJArray()
  for seat in 0 ..< Seats:
    powers.add(%PowerNames[gs.sim.powerOf[seat]])
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "cogiavelli.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "powers": powers,
    "config": {
      "years": gs.config.years,
      "seed": gs.config.seed,
      "press": gs.config.press,
      "sampled": true,
      "victoryCities": VictoryCities,
      "totalCities": TotalCities,
      "map": "italy1499"
    },
    "events": events,
    "results": results
  }

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    state.trajectory.finishNativeTrajectory(results)
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection. Results carry POLICY
    ## names for the platform; the final frame carries the table aliases.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "cities": results["cities"],
      "ducats": results["ducats"],
      "units": results["units"],
      "powers": results["powers"],
      "names": aliasNames,
      "years": results["years"],
      "reason": results["reason"],
      "conqueror": results["conqueror"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "cogiavelli: writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData,
    "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD")
  ## The certifier pings /global after the player pods start, so keep
  ## /healthz and /global answering for a bounded grace before exiting.
  echo "cogiavelli: artifacts written; serving a ",
    ShutdownGraceSeconds.int, "s shutdown grace"
  sleep(int(ShutdownGraceSeconds * 1000))
  echo "cogiavelli: episode complete, shutting down"
  quit(0)

proc phaseLabel(sim: Sim): string =
  seasonName(sim.season) & " " & $sim.year & " " &
    (if sim.phase == phPress: "letters" else: "orders")

proc failEpisode(runtimeConfig: RuntimeConfig, kind: FailureKind, seat: int, power, phase,
    reason, rawResponse: string, evidence: seq[DecisionAttempt] = @[],
    observation: JsonNode = nil) =
  discard runtimeConfig
  var failureJson: JsonNode
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    let policyName =
      if seat >= 0 and seat < state.config.players.len:
        state.config.players[seat].name
      else: ""
    let detail = "seat " & $seat & " (" & power & ", " & $state.sim.season &
      " " & $state.sim.year & " " & phase & "): " & reason &
      (if rawResponse.len > 0: " | raw_response=" & rawResponse else: "")
    failureJson = %*{
      "failed_policy_index": max(seat, 0),
      "kind": $kind,
      "message": cleanText(detail, 1900)
    }
    if not state.trajectory.isNil and seat >= 0:
      let obs = if observation.isNil: state.sim.observationJson(seat) else: observation
      state.trajectory.recordFailedDecision(state.sim.events.len, seat,
        policyName, obs, evidence, state.selection, reason, rawResponse)
      state.trajectory.failNativeTrajectory(seat, reason, rawResponse)
    let errorFrame = %*{
      "type": "final",
      "done": true,
      "failed": true,
      "seat": seat,
      "power": power,
      "reason": reason
    }
    for slot, socket in state.playerSockets:
      try:
        socket.send($errorFrame)
      except CatchableError:
        discard
  echo "cogiavelli: episode failed for seat ", seat, " (", power, "): ", reason
  let failureUri = getEnv("COGAME_PLAYER_FAILURE_URI").strip()
  if failureUri.len > 0:
    try:
      writeArtifact(failureUri, $failureJson, "application/json",
        "COGAME_PLAYER_FAILURE_METHOD")
    except CatchableError as error:
      echo "cogiavelli: failed to write COGAME_PLAYER_FAILURE_URI: ", error.msg
  sleep(200)
  quit(1)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allReady = false
      withLock stateLock:
        if state.playerSockets.len >= config.tokens.len:
          allReady = true
          for slot in 0 ..< config.tokens.len:
            if not state.promptDelivered[slot]:
              allReady = false
              break
      if allReady:
        break
      sleep(100)

    var regErrSeat = -1
    var regErrMsg = ""
    withLock stateLock:
      for slot in 0 ..< config.tokens.len:
        if state.registrationErrors[slot].len > 0:
          regErrSeat = slot
          regErrMsg = state.registrationErrors[slot]
          break
      if regErrSeat < 0:
        state.started = true
        echo "cogiavelli: starting with ", state.playerSockets.len, "/",
          config.tokens.len, " players connected"
        state.broadcastLocked()
    if regErrSeat >= 0:
      failEpisode(runtimeConfig, playerError, regErrSeat,
        PowerNames[state.sim.powerOf[regErrSeat]], "registration", regErrMsg, "")

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. The
    ## hosted dispatcher hands the timeout only to its own worker sidecar,
    ## NOT to the game container, so when the env is silent assume the
    ## configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "cogiavelli: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var phase: PhaseKind
      var seats: seq[int]
      var prompts: seq[string]
      var kinds: seq[ScriptKind]
      withLock stateLock:
        if state.sim.done:
          break
        ## The deadline is checked before every batch, which is also before
        ## every season transition: a transition only ever happens inside
        ## the apply that closes a phase.
        if playDeadline > 0.0 and epochTime() > playDeadline:
          echo "cogiavelli: episode deadline reached after ",
            state.sim.yearsPlayed, "/", config.years, " years; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        phase = state.sim.phase
        simCopy = state.sim
        prompts = state.prompts
        kinds = state.scripted
      if seats.len == 0:
        echo "cogiavelli: no seat is pending in ", $phase, "; settling"
        withLock stateLock:
          state.sim.endEarly()
          state.broadcastLocked()
        break

      ## The slow part (one batch for every open seat at once) runs outside
      ## the lock on a snapshot; only this thread mutates the sim, so the
      ## snapshot cannot go stale.
      var captureViews: seq[JsonNode]
      if not state.trajectory.isNil:
        for seat in seats: captureViews.add(simCopy.observationJson(seat))
      var decisions: seq[Decision]
      try:
        decisions = decideAll(client, state.selection, simCopy, phase, seats, prompts, kinds)
      except ModelDecisionError as error:
        var evidence: seq[DecisionAttempt]
        var obs: JsonNode
        if not state.trajectory.isNil:
          for index, seat in seats:
            if kinds[seat] != skNone: continue
            if seat == error.seat:
              evidence = client.nativeAttempts[seat]
              obs = captureViews[index]
            else:
              state.trajectory.recordFailedDecision(simCopy.events.len, seat,
                config.players[seat].name, captureViews[index],
                client.nativeAttempts[seat], state.selection, error.reason,
                "", peer = true)
        failEpisode(runtimeConfig, error.kind, error.seat, error.power, $error.phase,
          error.reason, error.rawResponse, evidence, obs)

      withLock stateLock:
        echo "cogiavelli: ", phaseLabel(state.sim), " — ", seats.len,
          " seats at ", (epochTime() - gameStart).int, "s"
        for index, seat in seats:
          if state.sim.done or not state.sim.pending[seat]:
            continue
          let decision = decisions[index]
          let eventIndex = state.sim.events.len
          try:
            if phase == phPress:
              state.sim.applyPress(seat, decision.broadcast, decision.letters,
                decision.pledges, decision.notes, decision.scripted)
            else:
              state.sim.applyOrders(seat, decision.orders, decision.spend,
                decision.builds, decision.notes, decision.scripted)
          except CogiavelliError as error:
            let evidence =
              if seat >= 0 and seat < client.nativeAttempts.len:
                client.nativeAttempts[seat]
              else: @[]
            let obs = if not state.trajectory.isNil: captureViews[index] else: nil
            stateLock.release()
            failEpisode(runtimeConfig, playerError, seat, PowerNames[simCopy.powerOf[seat]],
              $phase, error.msg, $decision.decisionReply(phase), evidence, obs)
          if not state.trajectory.isNil:
            let applied = state.sim.events[eventIndex]
            state.trajectory.recordAppliedDecision(eventIndex, seat,
              config.players[seat].name, captureViews[index], applied.executedReply(),
              applied.scripted, kinds[seat] != skNone, client.nativeAttempts[seat],
              state.selection)
        state.broadcastLocked()

      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      elif name.endsWith(".json"): "application/json"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8")

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "cogiavelli: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "cogiavelli.player.v1",
        "slot": slot,
        "power": PowerNames[state.sim.powerOf[slot]],
        "name": state.sim.names[slot],
        "years": state.config.years,
        "press": state.config.press
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.len > MaxPromptLen:
            prompt = cleanText(prompt, MaxPromptLen)
          let node = payload{"scripted"}
          var kind = skNone
          var regErr = ""
          if not node.isNil and node.kind != JNull:
            if node.kind != JString:
              regErr = "prompt frame 'scripted' must be a string"
            else:
              try:
                kind = parseScriptKind(node.getStr())
              except CogiavelliError as error:
                regErr = error.msg
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = kind
            state.registrationErrors[slot] = regErr
            state.promptDelivered[slot] = true
          if regErr.len > 0:
            echo "cogiavelli: slot ", slot, " invalid registration: ", regErr
          else:
            echo "cogiavelli: slot ", slot, " delivered a prompt (",
              prompt.len, " chars",
              (if kind != skNone: ", scripted " & $kind else: ""), ")"
      except CatchableError as error:
        echo "cogiavelli: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.years = payload["config"]{"years"}.getInt(4)
  result.seed = payload["config"]{"seed"}.getInt(0)
  result.press = payload["config"]{"press"}.getBool(true)
  ## The replay carries the episode's fitted cap; never re-fit it.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  let enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("cogiavelli.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "powers": payload{"powers"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "cogiavelli: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(CogiavelliError, "tokens and players must align")
  state.config = config
  state.selection = promptSelection(parseJson(
    if runtimeConfig.config.len > 0: runtimeConfig.config else: "{}"))
  state.sim = initSim(config)
  state.trajectory = initNativeTrajectory(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  state.promptDelivered = newSeq[bool](config.players.len)
  state.registrationErrors = newSeq[string](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "cogiavelli: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
