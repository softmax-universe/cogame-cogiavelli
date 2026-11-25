"""Exercise complete native server/player games with a deterministic local HTTP model service."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


FAILURE_SLOTS = {"2", "4"}


def make_provider(mode: str, call_log: list):
    class Provider(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_POST(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            body = json.loads(raw)
            user = body["messages"][0]["content"]
            season, year = re.match(r"(SPRING|SUMMER|AUTUMN) (\d+)", user).groups()
            slot = self.headers["X-Coworld-Player-Slot"]
            call_log.append((slot, year, season, " — LETTERS." in user))
            assert "PRIVATE_OPERATOR_" + slot in user
            assert all("PRIVATE_OPERATOR_" + str(i) not in user for i in range(6) if str(i) != slot)
            assert "SPECTATOR_POLICY_" not in user and "SPECTATOR_POLICY_" not in body["system"]
            fail_slot = slot in FAILURE_SLOTS
            if fail_slot and mode == "http_error":
                self.send_error(503, f"FIXTURE_PROVIDER_UNAVAILABLE_{slot}")
                return
            if fail_slot and mode == "disconnect":
                self.close_connection = True
                return
            if fail_slot and mode == "always_invalid":
                text = f"HTTP 503: RAW_INVALID_MODEL_OUTPUT_12345_{slot}"
            elif fail_slot and mode == "illegal_order" and " — LETTERS." not in user:
                text = json.dumps({"orders": ["A NOT_A_PROVINCE - NOPE"], "spend": [], "notes": "bad"})
            else:
                notes = "PRIVATE_CAPTURE_" + slot
                if " — LETTERS." in user:
                    action = {
                        "broadcast": f"PUBLIC_PHASE_{year}_{season.lower()}_{slot}",
                        "letters": [],
                        "pledges": [],
                        "notes": notes,
                    }
                else:
                    legal = user.split("YOUR UNITS AND EVERY LEGAL ORDER:\n")[1].split("\n\n")[0]
                    orders = re.findall(r"^  [AF] [A-Z]+ \([^\n]*?\): ([^|\n]+)", legal, re.M)
                    action = {"orders": [o.strip() for o in orders], "spend": [], "notes": notes}
                    if season == "AUTUMN":
                        action["builds"] = []
                text = json.dumps(action)
                if season == "SPRING":
                    text = f"```json\n{text}\n```"
            response = json.dumps(
                {
                    "model": body["model"],
                    "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": text}],
                    "usage": None if year == "1500" and season == "SUMMER" else {"input_tokens": 100, "output_tokens": 20},
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
            self.end_headers()
            self.wfile.write(response)

    return Provider


def run(game, player, output, variant, name, capture, seat_roles, provider_mode="normal", model_enabled=True, expected_kind=None):
    root = output / name
    root.mkdir(mode=0o700)
    config = dict(variant["game_config"])
    seats = 6
    config.update(
        seed=42,
        years=1 if expected_kind else min(config.get("years", 4), 2),
        turnDelayMs=0,
        players=[{"name": f"SPECTATOR_POLICY_{i}"} for i in range(seats)],
        llmTimeoutSeconds=5,
        player_connect_timeout_seconds=10,
        episodeTimeoutSeconds=120,
        tokens=[f"fixture-{i}" for i in range(seats)],
    )
    (root / "config.json").write_text(json.dumps(config))
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    env = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        env.pop(key, None)
    episode = f"cogiavelli-native-{name}"
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_PLAYER_FAILURE_URI=(root / "player_failure.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=episode,
        COWORLD_GAME_VERSION="identity-fixture",
        COWORLD_SOURCE_REVISION="a" * 40,
    )
    if not capture:
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    call_log = []
    provider = ThreadingHTTPServer(("127.0.0.1", 0), make_provider(provider_mode, call_log))
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    if model_enabled:
        env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{provider.server_port}"
        env["COWORLD_LLM_MODEL"] = "native-capture-fixture"
    children = []
    streams = []
    try:
        log = (root / "game.log").open("wb")
        streams.append(log)
        server = subprocess.Popen([str(game)], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(server)
        for _ in range(100):
            assert server.poll() is None, f"game exited before readiness; see {root / 'game.log'}"
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        else:
            raise TimeoutError("native game did not become ready")
        for seat in range(seats):
            log = (root / f"player-{seat}.log").open("wb")
            streams.append(log)
            player_env = dict(env, PLAYER_PROMPT=f"PRIVATE_OPERATOR_{seat}", COWORLD_TIMEOUT_SECONDS="120")
            if seat_roles[seat]:
                player_env["PLAYER_SCRIPTED"] = seat_roles[seat]
            else:
                player_env.pop("PLAYER_SCRIPTED", None)
            player_env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}"
            children.append(subprocess.Popen([str(player)], env=player_env, stdout=log, stderr=subprocess.STDOUT))
        rc = server.wait(timeout=120)
        for child in children[1:]:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        model_seats = [i for i, role in enumerate(seat_roles) if not role]
        if expected_kind:
            assert rc != 0, f"expected non-zero exit for {name}, got 0"
            assert not (root / "results.json").exists(), f"failed episode must not write fake results.json in {name}"
            failure = json.loads((root / "player_failure.json").read_text())
            assert set(failure.keys()) == {"failed_policy_index", "kind", "message"}, failure
            failed_seat = 2 if model_enabled else model_seats[0]
            assert failure["failed_policy_index"] == failed_seat and failure["kind"] == expected_kind, failure
            assert failure["message"]
            if provider_mode == "always_invalid":
                assert "RAW_INVALID_MODEL_OUTPUT_12345" in failure["message"]
            elif provider_mode == "illegal_order":
                assert "A NOT_A_PROVINCE - NOPE" in failure["message"]
            elif provider_mode == "http_error":
                assert "503" in failure["message"] and "FIXTURE_PROVIDER_UNAVAILABLE" in failure["message"]
            expected_calls = [(str(i), "1499", "SPRING", config["press"]) for i in model_seats] if model_enabled else []
            observed = Counter(call_log)
            if provider_mode == "disconnect":
                # libcurl may resend on a fresh connection after a pooled socket closes
                # before any response. Only the interrupted seat can reach the handler twice.
                interrupted = (str(failed_seat), "1499", "SPRING", config["press"])
                assert observed[interrupted] in (1, 2), call_log
                observed[interrupted] = 1
            assert observed == Counter(expected_calls), call_log
            if capture:
                rows = [json.loads(line) for line in (root / "trajectory.jsonl").read_text().splitlines()]
                assert rows[-1]["status"] == "failed"
                assert "scores" not in rows[-1]["outcome"] and rows[-1]["participant_outcomes"] == {}
                if provider_mode == "http_error":
                    assert "FIXTURE_PROVIDER_UNAVAILABLE" in rows[-1]["outcome"]["raw_response"]
                assert rows[-1]["outcome"]["seat"] == failed_seat
                assert sorted(int(row["seat"]) for row in rows[:-1]) == model_seats
                for row in rows[:-1]:
                    slot = row["seat"]
                    assert row["executed_action"] is None and row["selected_attempt_id"] is None
                    attempt, = row["attempts"]
                    assert attempt["policy"] == "SPECTATOR_POLICY_" + slot and attempt["origin"] == "model"
                    if model_enabled:
                        assert "PRIVATE_OPERATOR_" + slot in attempt["request"]["messages"][0]["content"]
                    if not model_enabled or slot in FAILURE_SLOTS:
                        assert row["action_status"] == "rejected" and not attempt["accepted"]
                        assert attempt["rejection_reason"]
                        if provider_mode == "always_invalid":
                            assert f"RAW_INVALID_MODEL_OUTPUT_12345_{slot}" in attempt["response"]
                        elif provider_mode == "http_error":
                            assert f"FIXTURE_PROVIDER_UNAVAILABLE_{slot}" in attempt["raw_response"]
                    else:
                        assert row["action_status"] == "missing" and attempt["accepted"]
                        assert attempt["parsed_action"]["notes"] == "PRIVATE_CAPTURE_" + slot
            return failure, call_log

        assert rc == 0, f"game failed unexpectedly ({rc}); see {root / 'game.log'}"
        assert not (root / "player_failure.json").exists()
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert results["reason"] in ("complete", "conquest")
        assert len(results["scores"]) == seats
        events = [e for e in replay["events"] if e["kind"] in ("press", "orders")]
        expected_calls = []
        for event in events:
            if event["seat"] in model_seats:
                slot, year, season = str(event["seat"]), str(event["year"]), event["season"]
                expected_calls.append((slot, year, season.upper(), event["kind"] == "press"))
                if event["kind"] == "press":
                    assert event["broadcast"] == f"PUBLIC_PHASE_{year}_{season.lower()}_{slot}"
        assert Counter(call_log) == Counter(expected_calls), call_log
        assert set(int(call[0]) for call in call_log) == set(model_seats)
        if capture:
            trace = root / "trajectory.jsonl"
            rows = [json.loads(line) for line in trace.read_text().splitlines()]
            assert trace.stat().st_mode & 0o077 == 0
            assert rows[-1]["status"] == "completed" and rows[-1]["outcome"] == results
            assert len(events) == len(rows) - 1
            for event, row in zip(events, rows[:-1], strict=True):
                assert event["seat"] == int(row["seat"])
                assert row["action_status"] == "accepted"
                if seat_roles[event["seat"]]:
                    assert row["attempts"][0]["origin"] == "unknown"
                else:
                    attempt, = row["attempts"]
                    assert attempt["origin"] == "model" and attempt["accepted"]
                    assert row["selected_attempt_id"] == attempt["attempt_id"]
                    assert attempt["parsed_action"] == row["executed_action"]
                    assert attempt["platform_call_id"] is not None
                    text = attempt["response"]
                    if event["season"].lower() == "spring":
                        assert text.startswith("```json\n") and text.endswith("\n```")
                        text = text[8:-4]
                    action = json.loads(text)
                    assert action["notes"] == "PRIVATE_CAPTURE_" + row["seat"]
                    field = "orders" if event["kind"] == "orders" else "broadcast"
                    assert action[field] == event[field]
        return results, replay
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=5)
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()


def main():
    game, player, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    destination.mkdir(mode=0o700, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    mixed_roles = ["", "condottiere", "", "banker", "", ""]
    baseline_roles = ["condottiere", "banker", "condottiere", "banker", "condottiere", "banker"]

    # 1. Model player vs explicit baseline opponents (both variants, capture on/off parity)
    for variant in manifest["variants"]:
        captured = run(game, player, destination, variant, f"{variant['id']}-model-capture", True, mixed_roles)
        ordinary = run(game, player, destination, variant, f"{variant['id']}-model-plain", False, mixed_roles)
        assert captured == ordinary, "capture changed the native outcome or replay"

    # 2. Explicit failure when model returns invalid output (preserves raw data, no fallback)
    run(game, player, destination, manifest["variants"][0], "fail-invalid-reply", True, mixed_roles,
        provider_mode="always_invalid", expected_kind="player_error")

    # 3. Explicit failure when model returns illegal order (preserves raw data, no silent hold/fallback)
    run(game, player, destination, manifest["variants"][1], "fail-illegal-order", True, mixed_roles,
        provider_mode="illegal_order", expected_kind="player_error")

    # 4. Explicit failure when model seat has no LLM transport configured (no offline fallback)
    run(game, player, destination, manifest["variants"][0], "fail-no-transport", True, mixed_roles,
        model_enabled=False, expected_kind="episode_inconclusive")

    for mode in ("http_error", "disconnect"):
        run(game, player, destination, manifest["variants"][0], f"fail-{mode}", True, mixed_roles,
            provider_mode=mode, expected_kind="episode_inconclusive")

    # 5. Explicit baseline-only game completes offline without LLM credentials
    run(game, player, destination, manifest["variants"][0], "baselines-offline", True, baseline_roles,
        model_enabled=False)

    print("native server/player verification passed: HTTP model vs baselines, one call per decision, attributed failures, offline baselines")


if __name__ == "__main__":
    main()
