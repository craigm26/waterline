"""Collect renders/iter*/critique.json into the Track 2 evidence: score chart + iteration strip.

Writes renders/loop_report.json (for the page) and renders/loop_score.png and renders/iteration_strip.png
(for slides and video). Usage: python scripts/loop_report.py [--frame hs_rank2_4ft.png]
"""
import argparse, json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
R = ROOT / "renders"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", default="ferry_s1.png", help="the still to show across iterations")
    a = ap.parse_args()
    its = sorted((d for d in R.glob("iter*") if (d / "critique.json").exists()),
                 key=lambda d: int(re.sub(r"\D", "", d.name) or 0))
    rows = []
    for d in its:
        c = json.loads((d / "critique.json").read_text(encoding="utf-8"))
        top = sorted(c.get("defects", []), key=lambda x: {"high": 0, "med": 1, "low": 2}.get(x.get("severity"), 3))
        rows.append({"iter": d.name, "score": c.get("score"), "items": c.get("items", {}),
                     "verify": c.get("verify_score"), "top_defect": top[0]["evidence"] if top else None,
                     "frame": f"{d.name}/{a.frame}" if (d / a.frame).exists() else None})
    (R / "loop_report.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    if not rows:
        print("no critique.json yet: run section 9b first"); return
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(8, 3.2), dpi=150)
    x = range(len(rows))
    ax.plot(x, [r["score"] for r in rows], "o-", color="#3fb6e8", lw=2, label="rubric score (render vs reality)")
    if any(r["verify"] is not None for r in rows):
        ax.plot(x, [r["verify"] for r in rows], "s--", color="#e8a33f", lw=1.5, label="311 verification score")
    ax.axhline(0.85, color="#888", lw=0.8, ls=":"); ax.set_ylim(0, 1)
    ax.set_xticks(list(x), [r["iter"] for r in rows]); ax.legend(frameon=False, fontsize=8)
    for s in ("top", "right"): ax.spines[s].set_visible(False)
    fig.tight_layout(); fig.savefig(R / "loop_score.png"); plt.close(fig)
    from PIL import Image, ImageDraw
    ims = [(r, Image.open(R / r["frame"]).convert("RGB")) for r in rows if r["frame"]]
    if ims:
        w = 420; th = [(r, im.resize((w, int(im.height * w / im.width)))) for r, im in ims]
        h = max(t.height for _, t in th)
        sheet = Image.new("RGB", (w * len(th), h + 34), (10, 16, 22)); dr = ImageDraw.Draw(sheet)
        for i, (r, t) in enumerate(th):
            sheet.paste(t, (i * w, 0)); dr.text((i * w + 8, h + 9), f"{r['iter']}  score {r['score']:.2f}", fill=(230, 236, 242))
        sheet.save(R / "iteration_strip.png", optimize=True)
    print(f"{len(rows)} iterations -> renders/loop_report.json, loop_score.png, iteration_strip.png")


if __name__ == "__main__":
    main()
