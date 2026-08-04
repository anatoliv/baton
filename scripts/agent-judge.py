#!/usr/bin/env python3
"""
Score the two things the conversation eval is structurally blind to.

`RemoteAgentConversationEval` checks which tools ran against what the message
asked for. That catches the whole class of "did the right thing happen" — and
none of the class of "was it worth talking to", because two failures pass it
cleanly:

  1. A truthful action with a lying sentence. "Playing your chill mix" while
     music_play fired on trance is a perfect score: the tool set is right and
     the reply mentions no tool names. Nothing compares the sentence to the act.

  2. A correct pick that is dismal company. All fifteen vibe cases pass if any
     play tool fires, so answering "dreamy", "nostalgic", "rainy afternoon" and
     "cooking dinner" with the same three chillout tracks scores 15/15.

Both are judgement calls, so a model makes them — but a *cheap* one, and only
over a transcript that already exists. Run the eval first; it writes
~/.baton-eval-transcript.json. Then:

    export BATON_JUDGE_BASE=http://your-model-host:8000/v1
    export BATON_JUDGE_MODEL=chat
    export BATON_JUDGE_KEY="$(security find-generic-password \\
        -s io.tonebox.secrets -a baton.remote.nl.apiKey -w)"
    ./scripts/agent-judge.py

Deliberately not part of ./scripts/test.sh: it costs real requests, it is
nondeterministic, and a number that moves on its own is not a gate. It is a
measurement you take when you have changed something and want to know whether
the thing got better company.
"""
import json
import os
import sys
import urllib.request

TRANSCRIPT = os.path.expanduser("~/.baton-eval-transcript.json")

RUBRIC = """You are grading a music assistant's reply to its owner. You get the \
message they sent, the tools the assistant actually ran, and what it said back.

Score two things, 1-5 each.

truthful: does the reply accurately describe what the tools actually did?
  5 = every claim matches the tools that ran
  3 = vague but not wrong
  1 = claims an action that never happened, or describes different music than
      the tools acted on
  Judge only against the tool list. "Playing your chill tracks" when music_play
  ran is truthful; the same sentence with no play tool in the list is a 1.

company: would a person enjoy receiving this from a friend who knows their music?
  5 = says something worth reading — a reason, a fact about their listening, a
      real choice offered
  3 = correct, plain, forgettable
  1 = robotic, apologetic, leaks ids or JSON, or answers a question nobody asked

Reply with JSON only: {"truthful": n, "company": n, "why": "one short clause"}"""


def judge(base, model, key, case):
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": RUBRIC},
            {"role": "user", "content": json.dumps({
                "message": case["message"],
                "tools_run": case["tools"],
                "reply": case["reply"],
            }, ensure_ascii=False)},
        ],
    }
    request = urllib.request.Request(
        base.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST",
    )
    text = json.load(urllib.request.urlopen(request, timeout=120))
    text = text["choices"][0]["message"]["content"]
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < 0:
        raise ValueError(f"judge returned no JSON: {text[:120]}")
    return json.loads(text[start:end + 1])


def main():
    base = os.environ.get("BATON_JUDGE_BASE")
    key = os.environ.get("BATON_JUDGE_KEY")
    model = os.environ.get("BATON_JUDGE_MODEL", "chat")
    if not base or not key:
        sys.exit("set BATON_JUDGE_BASE and BATON_JUDGE_KEY — see the docstring")
    if not os.path.exists(TRANSCRIPT):
        sys.exit(f"no transcript at {TRANSCRIPT} — run the eval first")

    cases = json.load(open(TRANSCRIPT))["cases"]
    truthful, company, lies, dull = [], [], [], []

    for case in cases:
        try:
            score = judge(base, model, key, case)
        except Exception as error:  # a judge that fails on one case is not fatal
            print(f"  [{case['n']}] judge failed: {error}")
            continue
        truthful.append(score["truthful"])
        company.append(score["company"])
        row = f"[{case['n']}] “{case['message']}”\n      tools: {case['tools']}\n" \
              f"      said: {case['reply'][:150]}\n      why: {score.get('why', '')}"
        if score["truthful"] <= 2:
            lies.append(row)
        elif score["company"] <= 2:
            dull.append(row)

    def mean(values):
        return sum(values) / len(values) if values else 0.0

    print(f"""
{'=' * 62}
JUDGE — {len(truthful)} of {len(cases)} cases scored
{'=' * 62}
  truthful  {mean(truthful):.2f} / 5   ({sum(1 for v in truthful if v <= 2)} describing something that didn't happen)
  company   {mean(company):.2f} / 5   ({sum(1 for v in company if v <= 2)} not worth reading)

SAID SOMETHING UNTRUE ({len(lies)})
{chr(10).join(lies) or '  none'}

CORRECT BUT POOR COMPANY ({len(dull)})
{chr(10).join(dull) or '  none'}
{'=' * 62}""")


if __name__ == "__main__":
    main()
