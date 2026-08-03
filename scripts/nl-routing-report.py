#!/usr/bin/env python3
"""
Render the routing evaluation as a self-contained HTML report.

Reads the JSON that `nl-routing-eval.py --json` writes and emits a page that
opens over file:// with no network access — no CDN fonts, no external anything,
so it keeps working offline and inside the repo years from now.

  ./scripts/nl-routing-eval.py --json docs/nl-routing-results.json --runs 3
  ./scripts/nl-routing-report.py docs/nl-routing-results.json docs/nl-routing-evaluation.html

Colours are Baton's own (the orange from the site's tokens on a warm near-black),
with pass/warn/fail kept separate from the accent so status reads at a glance.
"""
import html, json, sys
from collections import Counter

def esc(s): return html.escape(str(s))


def row(r, n):
    tools = list(dict.fromkeys(r["tools"]))
    called = " ".join(
        f'<code class="tool{" bad" if t != r["expect"] else ""}">{esc(t)}</code>' for t in tools)
    args = esc(r["args"]) if r["args"] not in ("{}", "", None) else '<span class="none">no arguments</span>'
    runs = len(r["tools"])
    dots = "".join(f'<i class="{"y" if i < r["passes"] else "n"}"></i>' for i in range(runs))
    return f'''<tr data-status="{r['status']}">
      <td class="n">{n}</td>
      <td class="q">{esc(r['text'])}</td>
      <td class="ex"><code>{esc(r['expect'])}</code></td>
      <td class="ev">{called}<div class="args">{args}</div></td>
      <td class="runs" title="{r['passes']} of {runs} runs correct"><span class="dots">{dots}</span></td>
    </tr>'''


def case_note(r, text, kind):
    return f'''<div class="case {kind}">
      <div class="case-q">{esc(r["text"])}</div>
      <div class="case-ev"><span class="lbl">expected</span><code>{esc(r["expect"])}</code>
        <span class="lbl">got</span>{"".join(f'<code class="bad">{esc(t)}</code>' for t in dict.fromkeys(r["tools"]))}</div>
      <p>{text}</p>
    </div>'''


NOTES = {
    "add this artist to the queue":
        "“This artist” means the one currently playing, which the model cannot know from the "
        "message alone. Answering it properly needs two calls — read what is playing, then queue "
        "that artist — and Baton deliberately makes exactly one. Wrong in every run of every "
        "session, so it is a design limit rather than noise. Naming the artist works every time.",
    "play the album abbey road":
        "Falls to music_search. Passed every run of an earlier session and failed every run of a "
        "later one, with no change to the prompt — the clearest evidence here that repeated runs "
        "inside one session understate how much this drifts.",
    "crank it":
        "Slang with no object, sitting between “turn it up” and “put something on”. Correct in "
        "some sessions and not others.",
}
DEFAULT_NOTE = ("Routed to a different tool than expected. See the arguments for what the model "
                "thought was being asked.")


def build(data, runs_label):
    rows = data["single"] + data["context"]
    cats = []
    for r in rows:
        if r["cat"] not in cats:
            cats.append(r["cat"])

    body, n = [], 0
    for cat in cats:
        crows = [r for r in rows if r["cat"] == cat]
        ok = sum(1 for r in crows if r["status"] == "pass")
        body.append(f'<tr class="grp"><th colspan="5"><span>{esc(cat)}</span>'
                    f'<em>{ok}/{len(crows)}</em></th></tr>')
        for r in crows:
            n += 1
            body.append(row(r, n))

    counts = Counter(r["status"] for r in rows)
    bad = [r for r in rows if r["status"] != "pass"]
    ctx_ok = sum(1 for r in data["context"] if r["status"] == "pass")
    notes = "".join(case_note(r, NOTES.get(r["text"], DEFAULT_NOTE),
                              "fail" if r["status"] == "fail" else "flaky") for r in bad)

    return f'''<title>Baton — plain-English routing evaluation</title>
<style>
  :root {{
    --accent:#E98345;
    --bg:#FBF8F5; --panel:#FFFFFF; --sunken:#F3EEE9;
    --ink:#1E1815; --ink-dim:#5A4F48; --ink-faint:#8C7F76; --line:#E4DBD3;
    --pass:#3F7D55; --fail:#BE4A32; --flaky:#B07B1E;
    --fail-bg:#FBE9E5; --flaky-bg:#FAF0DC;
    --serif:Georgia,"Iowan Old Style","Times New Roman",serif;
    --sans:ui-sans-serif,system-ui,-apple-system,"Helvetica Neue",sans-serif;
    --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
  }}
  @media (prefers-color-scheme:dark) {{
    :root {{
      --bg:#171310; --panel:#1F1A16; --sunken:#241E19;
      --ink:#F2EBE5; --ink-dim:#B6A79C; --ink-faint:#8A7B71; --line:#332B25;
      --pass:#7FBF95; --fail:#E58A72; --flaky:#DCB463;
      --fail-bg:#33201B; --flaky-bg:#302617;
    }}
  }}
  :root[data-theme="dark"] {{
    --bg:#171310; --panel:#1F1A16; --sunken:#241E19;
    --ink:#F2EBE5; --ink-dim:#B6A79C; --ink-faint:#8A7B71; --line:#332B25;
    --pass:#7FBF95; --fail:#E58A72; --flaky:#DCB463;
    --fail-bg:#33201B; --flaky-bg:#302617;
  }}
  :root[data-theme="light"] {{
    --bg:#FBF8F5; --panel:#FFFFFF; --sunken:#F3EEE9;
    --ink:#1E1815; --ink-dim:#5A4F48; --ink-faint:#8C7F76; --line:#E4DBD3;
    --pass:#3F7D55; --fail:#BE4A32; --flaky:#B07B1E;
    --fail-bg:#FBE9E5; --flaky-bg:#FAF0DC;
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--ink); font-family:var(--sans);
    font-size:15px; line-height:1.55; -webkit-font-smoothing:antialiased; }}
  .wrap {{ max-width:1120px; margin:0 auto; padding:clamp(1.5rem,4vw,3.25rem) clamp(1rem,3vw,2rem) 4rem; }}
  header {{ border-bottom:1px solid var(--line); padding-bottom:1.6rem; }}
  .eyebrow {{ font-size:.7rem; letter-spacing:.18em; text-transform:uppercase; color:var(--ink-faint); margin:0 0 .55rem; }}
  h1 {{ font-family:var(--serif); font-size:clamp(1.8rem,4vw,2.6rem); line-height:1.1; margin:0 0 .5rem;
    font-weight:700; letter-spacing:-.015em; text-wrap:balance; }}
  .sub {{ color:var(--ink-dim); max-width:64ch; margin:0; }}
  .sub b {{ color:var(--ink); font-weight:620; }}
  .scores {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:1px;
    background:var(--line); border:1px solid var(--line); border-radius:12px; overflow:hidden; margin:1.9rem 0; }}
  .score {{ background:var(--panel); padding:1rem 1.1rem; }}
  .score .v {{ font-family:var(--serif); font-size:1.85rem; font-weight:700; line-height:1;
    font-variant-numeric:tabular-nums; letter-spacing:-.02em; }}
  .score .k {{ font-size:.74rem; text-transform:uppercase; letter-spacing:.09em; color:var(--ink-faint); margin-top:.42rem; }}
  .score.ok .v {{ color:var(--pass); }} .score.bad .v {{ color:var(--fail); }}
  h2 {{ font-family:var(--serif); font-size:1.2rem; margin:2.4rem 0 .7rem; font-weight:700; letter-spacing:-.01em; }}
  p.lead {{ color:var(--ink-dim); max-width:68ch; margin:0 0 1rem; }}
  .case {{ background:var(--panel); border:1px solid var(--line); border-left:3px solid var(--fail);
    border-radius:9px; padding:.95rem 1.1rem; margin:.7rem 0; }}
  .case.flaky {{ border-left-color:var(--flaky); }}
  .case-q {{ font-family:var(--mono); font-size:.86rem; }}
  .case-ev {{ display:flex; flex-wrap:wrap; align-items:center; gap:.4rem; margin:.5rem 0 .3rem; }}
  .lbl {{ font-size:.68rem; text-transform:uppercase; letter-spacing:.09em; color:var(--ink-faint); }}
  .case p {{ margin:.35rem 0 0; color:var(--ink-dim); font-size:.93rem; max-width:72ch; }}
  code {{ font-family:var(--mono); font-size:.79rem; background:var(--sunken); border:1px solid var(--line);
    border-radius:5px; padding:.1rem .38rem; color:var(--ink); }}
  code.bad {{ color:var(--fail); border-color:color-mix(in srgb,var(--fail) 35%,var(--line)); }}
  .controls {{ display:flex; flex-wrap:wrap; gap:.45rem; margin:1.1rem 0 .8rem; }}
  button {{ font:inherit; font-size:.83rem; padding:.34rem .8rem; border-radius:999px; cursor:pointer;
    background:var(--panel); color:var(--ink-dim); border:1px solid var(--line); }}
  button:hover {{ color:var(--ink); border-color:var(--ink-faint); }}
  button[aria-pressed="true"] {{ background:var(--accent); border-color:var(--accent); color:#231508; font-weight:600; }}
  button:focus-visible {{ outline:2px solid var(--accent); outline-offset:2px; }}
  .tablewrap {{ overflow-x:auto; border:1px solid var(--line); border-radius:12px; background:var(--panel); }}
  table {{ width:100%; border-collapse:collapse; font-size:.88rem; }}
  th,td {{ text-align:left; padding:.55rem .7rem; border-bottom:1px solid var(--line); vertical-align:top; }}
  thead th {{ position:sticky; top:0; background:var(--panel); z-index:2; font-size:.68rem; text-transform:uppercase;
    letter-spacing:.09em; color:var(--ink-faint); font-weight:600; }}
  tr.grp th {{ background:var(--sunken); font-size:.75rem; text-transform:uppercase; letter-spacing:.1em;
    color:var(--ink-dim); font-weight:650; display:flex; justify-content:space-between; align-items:baseline; }}
  tr.grp em {{ font-style:normal; font-variant-numeric:tabular-nums; color:var(--ink-faint); }}
  td.n {{ color:var(--ink-faint); font-variant-numeric:tabular-nums; font-size:.78rem; width:2.6rem; }}
  td.q {{ font-family:var(--mono); font-size:.83rem; min-width:15rem; }}
  td.ex code {{ background:none; border:none; padding:0; color:var(--ink-dim); }}
  td.ev {{ min-width:17rem; }}
  .args {{ font-family:var(--mono); font-size:.75rem; color:var(--ink-faint); margin-top:.28rem; word-break:break-word; }}
  .none {{ font-style:italic; }}
  .dots {{ display:inline-flex; gap:3px; }}
  .dots i {{ width:8px; height:8px; border-radius:2px; display:block; }}
  .dots i.y {{ background:var(--pass); }} .dots i.n {{ background:var(--fail); opacity:.55; }}
  tr[data-status="fail"] td {{ background:var(--fail-bg); }}
  tr[data-status="flaky"] td {{ background:var(--flaky-bg); }}
  .method {{ margin-top:2.6rem; padding-top:1.5rem; border-top:1px solid var(--line); }}
  .method dl {{ display:grid; grid-template-columns:auto 1fr; gap:.4rem 1.2rem; margin:.6rem 0 0; font-size:.9rem; }}
  .method dt {{ color:var(--ink-faint); font-size:.72rem; text-transform:uppercase; letter-spacing:.09em; padding-top:.22rem; }}
  .method dd {{ margin:0; color:var(--ink-dim); }}
  .caveat {{ background:var(--sunken); border:1px solid var(--line); border-radius:10px; padding:1rem 1.15rem; margin-top:1.4rem; }}
  .caveat h3 {{ margin:0 0 .4rem; font-size:.9rem; }}
  .caveat ul {{ margin:0; padding-left:1.1rem; color:var(--ink-dim); font-size:.9rem; }}
  .caveat li {{ margin:.3rem 0; }}
  @media (prefers-reduced-motion:reduce) {{ * {{ transition:none !important; }} }}
</style>

<div class="wrap">
<header>
  <p class="eyebrow">Baton · plain-English routing</p>
  <h1>Does plain English actually reach the right control?</h1>
  <p class="sub">{len(data['single'])} queries plus {len(data['context'])} follow-ups, each sent
  through Baton's real tool catalog to a local model, {runs_label}. Every row carries the tool
  the model chose and the arguments it returned — <b>the evidence is the model's own
  output</b>, not a summary of it.</p>
</header>

<div class="scores">
  <div class="score ok"><div class="v">{counts['pass']}/{len(rows)}</div><div class="k">correct in every run</div></div>
  <div class="score bad"><div class="v">{counts['fail'] + counts['flaky']}</div><div class="k">wrong or unstable</div></div>
  <div class="score ok"><div class="v">{ctx_ok}/{len(data['context'])}</div><div class="k">follow-ups with context</div></div>
  <div class="score"><div class="v">{len(cats)}</div><div class="k">categories</div></div>
</div>

<h2>What didn't work</h2>
<p class="lead">Stated here rather than left to be found in the table.</p>
{notes or '<p class="lead">Nothing — every query routed correctly in every run.</p>'}

<h2>Every query, with its evidence</h2>
<div class="controls">
  <button data-f="all" aria-pressed="true">All {len(rows)}</button>
  <button data-f="fail">Failures</button>
  <button data-f="flaky">Flaky</button>
  <button data-f="pass">Passing</button>
</div>
<div class="tablewrap">
<table>
  <thead><tr><th>#</th><th>Query sent</th><th>Expected</th><th>Tool called + arguments returned</th><th>Runs</th></tr></thead>
  <tbody>{"".join(body)}</tbody>
</table>
</div>

<div class="method">
  <h2>How this was measured</h2>
  <dl>
    <dt>Catalog</dt><dd>Pulled live from the running app's MCP server (<code>tools/list</code>), not a copy that could drift.</dd>
    <dt>Prompt</dt><dd>Baton's shipped system prompt, verbatim.</dd>
    <dt>Call</dt><dd><code>tool_choice: "required"</code>, exactly as Baton calls it.</dd>
    <dt>Scoring</dt><dd>A query counts as correct only if every run agrees.</dd>
    <dt>Reproduce</dt><dd><code>scripts/nl-routing-eval.py</code> then <code>scripts/nl-routing-report.py</code>.</dd>
  </dl>
  <div class="caveat">
    <h3>What this does not prove</h3>
    <ul>
      <li><b>Repeated runs in one sitting understate the drift.</b> Two separate three-run sessions,
        same prompt and same model, disagreed about which queries fail — one session had
        <code>play the album abbey road</code> passing every run, the next had it failing every run.
        Treat any single score as a snapshot.</li>
      <li>One model on one machine. A different model may route differently.</li>
      <li>The queries and the expected answers were written by the same author, so a category
        nobody thought of is still untested.</li>
      <li>Routing is not execution. A correct tool call still has to match something in the library.</li>
      <li>The model sometimes invents ids when a tool accepts them (<code>music_add_to_playlist</code>).
        Baton's tools validate their own inputs, so it fails rather than acting on one.</li>
    </ul>
  </div>
</div>
</div>

<script>
  const btns=[...document.querySelectorAll("button[data-f]")];
  const rows=[...document.querySelectorAll("tbody tr")];
  btns.forEach(b=>b.addEventListener("click",()=>{{
    btns.forEach(x=>x.setAttribute("aria-pressed", x===b));
    const f=b.dataset.f;
    rows.forEach(r=>{{ if(!r.classList.contains("grp")) r.hidden = !(f==="all"||r.dataset.status===f); }});
    document.querySelectorAll("tr.grp").forEach(g=>{{
      let any=false,n=g.nextElementSibling;
      while(n && !n.classList.contains("grp")){{ if(!n.hidden) any=true; n=n.nextElementSibling; }}
      g.hidden=!any;
    }});
  }}));
</script>'''


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = json.load(open(sys.argv[1]))
    runs = len(data["single"][0]["tools"])
    label = f"{runs} times over" if runs > 1 else "once"
    open(sys.argv[2], "w").write(build(data, label))
    print(f"wrote {sys.argv[2]}")
