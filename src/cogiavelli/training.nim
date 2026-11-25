## Opt-in private evidence for the unchanged simultaneous native decisions.
import std/[json, options, os]
import bitworld/decision_trajectory
import curly
import sim, prompts
export decision_trajectory

proc initNativeTrajectory*(config: GameConfig): DecisionTrajectory =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"), "cogiavelli-" & $config.seed,
    "cogiavelli", getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"))

proc nativeAttempt*(policy: string, turn, seat: int, body: string): DecisionAttempt =
  result = newDecisionAttempt($turn & "-" & $seat & "-attempt-0", policy, aoModel)
  result.request = parseJson(body)
  result.prompt = %*[{"role": "system", "content": result.request["system"]}]
  for message in result.request["messages"]: result.prompt.add(copy(message))
  result.decoder = newJObject()
  for key, value in result.request:
    if key notin ["model", "system", "messages", "anthropic_version"]:
      result.decoder[key] = copy(value)

proc receiveNativeResponse*(attempt: var DecisionAttempt, response: Response,
    latencyMs: int) =
  # Curly returns received, decompressed body bytes and parsed headers. Do not
  # manufacture a raw HTTP header block or claim unexposed transport facts.
  attempt.rawResponse = %response.body
  attempt.latencyMs = some(latencyMs.float)
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    let value = response.headers[header]
    if value.len > 0:
      case field
      of "call": attempt.platformCallId = some(value)
      of "model": attempt.modelIdentity = some(value)
      of "tokenizer": attempt.tokenizerIdentity = some(value)
      of "template": attempt.chatTemplateSha256 = some(value)

proc recordNativeMetadata*(attempt: var DecisionAttempt, payload: JsonNode) =
  if payload.kind != JObject: return
  if payload.hasKey("model") and payload["model"].kind == JString:
    attempt.model = some(payload["model"].getStr())
  if payload.hasKey("stop_reason") and payload["stop_reason"].kind == JString:
    attempt.stopReason = some(payload["stop_reason"].getStr())
  let usage = payload{"usage"}
  if not usage.isNil and usage.kind == JObject:
    if usage.hasKey("input_tokens") and usage["input_tokens"].kind == JInt: attempt.inputTokens = some(usage["input_tokens"].getInt())
    if usage.hasKey("output_tokens") and usage["output_tokens"].kind == JInt: attempt.outputTokens = some(usage["output_tokens"].getInt())

proc recordAppliedDecision*(trajectory: DecisionTrajectory, eventIndex, seat: int,
    policy: string, observation, applied: JsonNode, scripted, declaredScripted: bool,
    evidence: seq[DecisionAttempt], selection: PromptSelection) =
  if trajectory.isNil: return
  var attempts = evidence
  var selected = none(string)
  var status = asAccepted
  if scripted:
    doAssert declaredScripted, "implicit scripted fallback is not permitted"
    var attempt = newDecisionAttempt($eventIndex & "-" & $seat & "-scripted", policy, aoUnknown)
    attempt.parsedAction = applied
    attempt.accepted = true
    attempts.add(attempt)
    selected = some(attempt.attemptId)
  else:
    doAssert attempts.len > 0
    if attempts[^1].parsedAction != applied:
      attempts[^1].accepted = false
      attempts[^1].rejectionReason = some("native engine normalized the proposal")
    if attempts[^1].accepted: selected = some(attempts[^1].attemptId)
    else: status = asRejected
  var view = copy(observation)
  view["prompt_attempts"] = newJArray()
  for attempt in attempts:
    if attempt.origin == aoModel:
      view["prompt_attempts"].add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": promptMetadata(selection, attempt.request["system"].getStr(),
          attempt.request["messages"][0]["content"].getStr())})
  trajectory.recordDecision("event-" & $eventIndex, $seat, view, attempts,
    selected, applied, status)

proc recordFailedDecision*(trajectory: DecisionTrajectory, eventIndex, seat: int,
    policy: string, observation: JsonNode, evidence: seq[DecisionAttempt],
    selection: PromptSelection, reason, rawResponse: string, peer = false) =
  if trajectory.isNil: return
  var attempts = evidence
  if not peer:
    for attempt in attempts.mitems: attempt.accepted = false
  if attempts.len == 0:
    var attempt = newDecisionAttempt($eventIndex & "-" & $seat & "-failed", policy, aoModel)
    attempt.rawResponse = %rawResponse
    attempt.rejectionReason = some(reason)
    attempt.accepted = false
    attempts.add(attempt)
  var view = copy(observation)
  view["prompt_attempts"] = newJArray()
  for attempt in attempts:
    if attempt.origin == aoModel and attempt.request.kind == JObject and
        attempt.request.hasKey("system") and attempt.request.hasKey("messages"):
      view["prompt_attempts"].add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": promptMetadata(selection, attempt.request["system"].getStr(),
          attempt.request["messages"][0]["content"].getStr())})
  trajectory.recordDecision("event-" & $eventIndex & "-failed-" & $seat, $seat,
    view, attempts, none(string), newJNull(),
    (if peer and attempts[0].rejectionReason.isNone: asMissing else: asRejected),
    terminal = true)

proc failNativeTrajectory*(trajectory: DecisionTrajectory, seat: int,
    reason, rawResponse: string) =
  if trajectory.isNil: return
  trajectory.finish(esFailed, %*{
    "error": reason,
    "seat": seat,
    "raw_response": rawResponse
  }, newJObject())
  trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))

proc finishNativeTrajectory*(trajectory: DecisionTrajectory, outcome: JsonNode) =
  if trajectory.isNil: return
  var scores = newJObject()
  for seat in 0 ..< Seats: scores[$seat] = outcome["scores"][seat]
  trajectory.finish(if outcome["reason"].getStr() in ["complete", "conquest"]:
    esCompleted else: esTruncated, outcome, scores)
  trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
