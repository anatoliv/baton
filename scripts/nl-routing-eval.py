#!/usr/bin/env python3
"""
Measure whether Baton's plain-English chat control reaches the right tool.

Unit tests prove the plumbing against fabricated model responses; they say
nothing about the model's judgement. This sends real phrasings to a real model
with Baton's real tool catalog and its shipped system prompt, and reports which
tool came back — the routing quality, separate from whether the tools work.

The catalog is pulled from the *running app's* MCP server rather than copied, so
the evaluation can't drift from what ships. Baton must be open.

Because these models aren't deterministic, a query counts as correct only if
every run agrees. Three runs is the useful minimum: it separates a stable answer
from a lucky one.

  ./scripts/nl-routing-eval.py --base-url http://127.0.0.1:8000/v1 --model chat
  ./scripts/nl-routing-eval.py --runs 5 --json docs/nl-routing-results.json

The key is read from --key, else $BATON_EVAL_KEY. For a LiteLLM proxy that must
be its master key: LiteLLM answers an unrecognized key with 400 "No connected
db.", which reads like an outage and means the wrong key.
"""
import argparse, json, os, sys, time, urllib.request
from collections import Counter

MCP_JSON = os.path.expanduser("~/Library/Application Support/Baton/mcp.json")

# Verbatim from RemoteNaturalLanguage.systemPrompt. If that changes, change this
# — an evaluation of a prompt you don't ship measures nothing.
SYSTEM = """You control a music player for its owner, who is sending you short messages from a chat app. Translate the message into exactly one tool call.

Guidance:
- Prefer the most direct tool. "skip"/"next one" is music_next, not a search.
- Vibe requests ("something mellow", "focus music") are music_play with the vibe as the query, unless the person asks for a mix of a particular length — then use music_build_mix.
- Playing, queueing and playing-next are three different tools, and the words matter: music_play starts now and replaces the queue ("play X", "put on X"); music_queue_add appends to the end ("add X", "queue X", "queue up X"); music_play_next inserts after the current track, and only for "play X next" or "after this one".
- music_start_radio is only for an endless stream seeded from what is already playing ("more like this", "keep this going", "start a radio"). Naming an artist or song is music_play, not radio.
- When the message names an artist, album, or song, pass it through as the query verbatim rather than rewriting it.
- If the message is a question about what is playing, use music_now_playing.
- "this song", "this artist", "more of this" refer to the player state given at the end of this prompt — use the name from there, not the words "this artist", as the query.
- Use music_search only when the person wants to SEE results ("show me", "find", "do I have"). When they want to HEAR something, pick a playing tool. Never fall back to music_search because you are unsure.
- Earlier turns are there so follow-ups resolve: "select one of them", "the second one", "play that" refer to what you last listed or played. Pick the specific track from that context and pass its exact title as the query, rather than searching for the words the person just used."""

# Withheld from model routing in RemoteNaturalLanguage.withheldTools.
WITHHELD = {"audio_suspend", "audio_resume", "speak_summary", "music_delete_playlist"}

# Known-hard cases: measured and reported every run, but excluded from the
# exit code, so the gate stays green-on-no-NEW-regressions instead of being
# permanently red. Promote a case out of here the day it passes consistently.
XFAIL = {"i want to hear radiohead"}

# The app appends the live player state to the system prompt on every request
# (RemoteCommandRouter.playerContext). The harness sends a representative state
# so state-referring queries ("add this artist to the queue") are answerable,
# exactly as they are in the app.
PLAYER_CONTEXT = 'Player state: "So What" by Miles Davis, from the album "Kind of Blue" — track 3 of 12 in the queue.' 

# (query, [acceptable tools — first is primary], category)
CASES = [
    ("skip this", ["music_next"], "Transport"),
    ("next track please", ["music_next"], "Transport"),
    ("skip to the next song", ["music_next"], "Transport"),
    ("go back to the previous song", ["music_previous"], "Transport"),
    ("previous track", ["music_previous"], "Transport"),
    ("stop the music", ["music_stop"], "Transport"),
    ("pause for a second", ["music_pause"], "Transport"),
    ("hold on, pause it", ["music_pause"], "Transport"),
    ("start it again", ["music_resume"], "Transport"),
    ("carry on playing", ["music_resume"], "Transport"),

    ("turn it up", ["music_set_volume"], "Volume"),
    ("turn it down a bit", ["music_set_volume"], "Volume"),
    ("make it quieter", ["music_set_volume"], "Volume"),
    ("set the volume to 30", ["music_set_volume"], "Volume"),
    ("volume 65", ["music_set_volume"], "Volume"),
    ("way too loud", ["music_set_volume"], "Volume"),
    ("crank it", ["music_set_volume"], "Volume"),
    ("mute it", ["music_set_volume", "music_pause"], "Volume"),

    ("put on some jazz", ["music_play"], "Play & search"),
    ("play kind of blue by miles davis", ["music_play"], "Play & search"),
    ("i want to hear the beatles", ["music_play"], "Play & search"),
    ("something mellow please", ["music_play"], "Play & search"),
    ("play some 90s house", ["music_play"], "Play & search"),
    ("put on radiohead", ["music_play"], "Play & search"),
    # The 0.12.5-era known-miss: a vague verb plus a band whose name starts
    # with "radio". Passes with a minimal 2-tool probe, fails with the full
    # catalog — minimal probes overstate, so it is pinned here at full strength
    # and carried as an expected failure (XFAIL) rather than papered over with
    # a "Radiohead is a band" prompt line.
    ("i want to hear radiohead", ["music_play"], "Play & search"),
    ("i fancy some blues", ["music_play"], "Play & search"),
    ("play the album abbey road", ["music_play"], "Play & search"),
    ("can you put on portishead", ["music_play"], "Play & search"),
    ("show me tracks for dido", ["music_search"], "Play & search"),
    ("do i have any coltrane", ["music_search"], "Play & search"),
    ("find songs by portishead", ["music_search"], "Play & search"),
    ("search for daft punk", ["music_search"], "Play & search"),
    ("have i got anything by bjork", ["music_search"], "Play & search"),
    # A search verb carrying a play intent. The parser claims "find" and searches
    # literally, so this only reaches the model as the retry after that search
    # came back empty — and the whole point of the retry is to hear the "and play".
    ("find lazy music and play", ["music_play"], "Play & search"),
    ("look up massive attack", ["music_search"], "Play & search"),
    ("what do i have from the 80s", ["music_search"], "Play & search"),

    ("add some beatles to the queue", ["music_queue_add"], "Queue"),
    ("queue up led zeppelin", ["music_queue_add"], "Queue"),
    ("put pink floyd on the end", ["music_queue_add"], "Queue"),
    ("add this artist to the queue", ["music_queue_add"], "Queue"),
    ("play bowie next", ["music_play_next"], "Queue"),
    ("after this one play nirvana", ["music_play_next"], "Queue"),
    ("stick miles davis on right after this", ["music_play_next"], "Queue"),
    ("what's in the queue", ["music_get_queue"], "Queue"),
    ("show me the queue", ["music_get_queue"], "Queue"),
    ("what's coming up", ["music_get_queue"], "Queue"),

    ("what's playing", ["music_now_playing"], "Status"),
    ("what song is this", ["music_now_playing"], "Status"),
    ("who sings this", ["music_now_playing"], "Status"),
    ("what album is this from", ["music_now_playing"], "Status"),
    ("how long is this track", ["music_now_playing"], "Status"),
    ("is anything playing right now", ["music_now_playing"], "Status"),

    ("i love this song", ["music_like"], "Likes & ratings"),
    ("favourite this track", ["music_like"], "Likes & ratings"),
    ("star this", ["music_like"], "Likes & ratings"),
    ("add this to my liked songs", ["music_like"], "Likes & ratings"),
    ("i don't like this, unlike it", ["music_like"], "Likes & ratings"),
    ("remove this from my favourites", ["music_like"], "Likes & ratings"),
    ("give this five stars", ["music_rate"], "Likes & ratings"),
    ("rate this 3", ["music_rate"], "Likes & ratings"),
    ("this deserves 4 stars", ["music_rate"], "Likes & ratings"),
    ("clear the rating on this", ["music_rate"], "Likes & ratings"),

    ("can you play focus playlist", ["music_play_playlist"], "Playlists"),
    ("play my focus playlist", ["music_play_playlist"], "Playlists"),
    ("put on the eurodance playlist", ["music_play_playlist"], "Playlists"),
    ("play the classic trance playlist", ["music_play_playlist"], "Playlists"),
    ("could you play my evening playlist", ["music_play_playlist"], "Playlists"),
    ("what playlists do i have", ["music_list_playlists"], "Playlists"),
    ("list my playlists", ["music_list_playlists"], "Playlists"),
    ("show me my playlists", ["music_list_playlists"], "Playlists"),
    ("make a playlist called road trip", ["music_create_playlist"], "Playlists"),
    ("add this song to my focus playlist", ["music_add_to_playlist"], "Playlists"),

    ("make me a 40 minute driving mix", ["music_build_mix"], "Mixes & radio"),
    ("build a one hour focus mix", ["music_build_mix"], "Mixes & radio"),
    ("i need 30 minutes of workout music", ["music_build_mix"], "Mixes & radio"),
    ("put together a chilled evening mix", ["music_build_mix"], "Mixes & radio"),
    ("more like this", ["music_start_radio"], "Mixes & radio"),
    ("keep this going", ["music_start_radio"], "Mixes & radio"),
    ("start a radio from this track", ["music_start_radio"], "Mixes & radio"),
    ("play stuff similar to this", ["music_start_radio"], "Mixes & radio"),

    ("shuffle the queue", ["music_set_shuffle"], "Modes"),
    ("turn shuffle off", ["music_set_shuffle"], "Modes"),
    ("mix up the order", ["music_set_shuffle"], "Modes"),
    ("turn off repeat", ["music_set_repeat"], "Modes"),
    ("repeat this song", ["music_set_repeat"], "Modes"),
    ("loop the whole queue", ["music_set_repeat"], "Modes"),
    ("jump to 2 minutes in", ["music_seek"], "Modes"),
    ("skip to 1:30", ["music_seek"], "Modes"),
    ("go back to the start of the track", ["music_seek"], "Modes"),
    ("stop playing in 20 minutes", ["music_sleep_timer"], "Modes"),
    ("turn on the bass boost eq", ["music_set_eq"], "Modes"),
    ("set crossfade to 5 seconds", ["music_set_crossfade"], "Modes"),

    ("could you possibly put on something quiet", ["music_play"], "Awkward phrasing"),
    ("pls skip", ["music_next"], "Awkward phrasing"),
    ("nex track", ["music_next"], "Awkward phrasing"),
    ("whats playin", ["music_now_playing"], "Awkward phrasing"),
    ("turn tha volume down", ["music_set_volume"], "Awkward phrasing"),
    ("i'm bored of this one", ["music_next"], "Awkward phrasing"),
    ("this is great, save it", ["music_like"], "Awkward phrasing"),
    ("too quiet i can barely hear it", ["music_set_volume"], "Awkward phrasing"),
    ("play somethin upbeat", ["music_play", "music_build_mix"], "Awkward phrasing"),
    ("gimme some techno", ["music_play"], "Awkward phrasing"),
]

# A realistic prior exchange, so follow-ups have something to refer back to.
HISTORY = [
    {"role": "user", "content": "show me tracks for dido"},
    {"role": "assistant", "content": "Songs\n• White Flag — Dido (3:41)\n"
                                     "• Dido (Original Mix) — 90s Kid (5:28)\n"
                                     "• Absolutely (Original Mix) — DIDO (7:23)"},
]
FOLLOW_UPS = [
    ("play the second one", ["music_play"]),
    ("select one of them", ["music_play"]),
    ("queue the first one", ["music_queue_add"]),
    ("play the last one", ["music_play"]),
    ("actually skip it", ["music_next"]),
    ("add them all to the queue", ["music_queue_add"]),
]


def load_catalog():
    """The tools Baton actually offers, from the running app's MCP server."""
    if not os.path.exists(MCP_JSON):
        sys.exit(f"no {MCP_JSON} — start Baton first, it writes that on launch")
    cfg = json.load(open(MCP_JSON))

    def rpc(method, params=None):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                           "params": params or {}}).encode()
        req = urllib.request.Request(cfg["url"], data=body, headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": f"Bearer {cfg['token']}",
            "MCP-Protocol-Version": "2025-06-18"})
        return urllib.request.urlopen(req, timeout=15).read().decode()

    rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "nl-routing-eval", "version": "1"}})
    raw = rpc("tools/list")
    if raw.lstrip().startswith("event:") or raw.lstrip().startswith("data:"):
        raw = "".join(l[5:].strip() for l in raw.splitlines() if l.startswith("data:"))
    tools = json.loads(raw)["result"]["tools"]
    offered = []
    for t in tools:
        if t["name"] in WITHHELD:
            continue
        schema = dict(t["inputSchema"])
        props = dict(schema.get("properties") or {})
        props.pop("song_ids", None)   # ids never appear in chat replies,
        props.pop("playlist_id", None)  # so the model could only invent them
        schema["properties"] = props
        offered.append({"type": "function", "function": {
            "name": t["name"], "description": t["description"], "parameters": schema}})
    return offered, len(tools)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default="http://127.0.0.1:8000/v1",
                   help="OpenAI-compatible root (default: %(default)s)")
    p.add_argument("--model", default="chat")
    p.add_argument("--key", default=os.environ.get("BATON_EVAL_KEY", ""))
    p.add_argument("--runs", type=int, default=3,
                   help="a query counts as correct only if every run agrees (default: %(default)s)")
    p.add_argument("--json", metavar="PATH", help="write per-query results here")
    args = p.parse_args()
    if not args.key:
        sys.exit("no key — pass --key or set BATON_EVAL_KEY")

    tools, total = load_catalog()
    print(f"{total} tools from the running app, {len(tools)} offered to the model")
    print(f"{args.model} at {args.base_url}, {args.runs} run(s)\n")

    def ask(messages):
        body = json.dumps({"model": args.model, "tool_choice": "required", "tools": tools,
                           "messages": [{"role": "system", "content": SYSTEM + "\n\n" + PLAYER_CONTEXT}] + messages}).encode()
        req = urllib.request.Request(args.base_url.rstrip("/") + "/chat/completions",
                                     data=body, headers={"Content-Type": "application/json",
                                                         "Authorization": f"Bearer {args.key}"})
        choice = json.loads(urllib.request.urlopen(req, timeout=180).read())["choices"][0]
        call = (choice["message"].get("tool_calls") or [None])[0]
        if not call:
            return None, choice.get("finish_reason", "")
        return call["function"]["name"], call["function"].get("arguments", "{}")

    started = time.time()
    results = []
    for text, expect, cat in CASES + [(t, e, "Follow-up (with context)") for t, e in FOLLOW_UPS]:
        history = HISTORY if cat.startswith("Follow-up") else []
        got, argstr = [], "{}"
        for _ in range(args.runs):
            try:
                name, a = ask(history + [{"role": "user", "content": text}])
            except Exception as exc:                      # noqa: BLE001 — report, don't crash the sweep
                name, a = "ERROR", str(exc)[:80]
            got.append(name)
            argstr = a
        hits = sum(1 for g in got if g in expect)
        status = "pass" if hits == args.runs else ("flaky" if hits else "fail")
        if status != "pass" and text in XFAIL:
            status = "xfail"
        results.append({"text": text, "cat": cat, "expect": expect[0],
                        "tools": got, "args": argstr, "passes": hits, "status": status})
        mark = {"pass": "ok  ", "flaky": "FLAKY", "fail": "FAIL", "xfail": "XFAIL"}[status]
        print(f"{mark} {text[:44]:44} -> {Counter(got).most_common(1)[0][0]}")

    counts = Counter(r["status"] for r in results)
    print(f"\n{counts['pass']}/{len(results)} correct in every run · "
          f"{counts['flaky']} flaky · {counts['fail']} consistently wrong · "
          f"{counts['xfail']} known-hard (excluded from exit code) "
          f"({round(time.time() - started)}s)")
    for r in results:
        if r["status"] != "pass":
            print(f"  {r['status']:5} {r['text']!r} -> {sorted(set(r['tools']))} (want {r['expect']})")

    if args.json:
        single = [r for r in results if not r["cat"].startswith("Follow-up")]
        context = [r for r in results if r["cat"].startswith("Follow-up")]
        json.dump({"single": single, "context": context}, open(args.json, "w"), indent=1)
        print(f"\nwrote {args.json}")
    return 1 if counts["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
