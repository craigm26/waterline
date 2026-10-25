"""Render harness for the Track 2 loop: render -> watch -> critique -> fix.

Serves demo/ locally, drives the 3D scenes the way a viewer would, and writes
what Argon needs to *watch* the result:

  renders/<tag>/
    ferry_s0..s3.png     one still per Ferry Building scenario (king tide ... stress test)
    hs_<name>_<ft>.png   hotspot drill-down stills at several water levels
    orbit.mp4            ~20 s screen recording of the scenes (Argon's video input)
    contact.png          all stills on one sheet
    manifest.json        what each frame shows + the numbers on screen at that moment

Usage:
  python scripts/render_watch.py --tag iter0           # baseline (Argon's single pass)
  python scripts/render_watch.py --tag iter1 --page path/to/rebuilt/index.html
Then feed renders/<tag>/ to the critique prompt (plan/argon-prompts.md section 9).
"""
import argparse, functools, http.server, json, shutil, subprocess, threading, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def serve(directory, port):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    h = functools.partial(Quiet, directory=str(directory))
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), h)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def shot(page, sel, path):
    """Viewport-clip screenshot: element screenshots wait for 'stable', which an auto-orbiting canvas never is."""
    page.eval_on_selector(sel, "el=>el.scrollIntoView({block:'center'})")
    time.sleep(0.4)
    bb = page.locator(sel).bounding_box()
    page.screenshot(path=path, clip=bb, animations="allow")


def text(page, sel):
    try:
        return page.locator(sel).first.inner_text(timeout=1000).strip()
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="iter0")
    ap.add_argument("--page", default=str(ROOT / "demo" / "index.html"), help="page to render (its folder is served)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--levels", default="1,4", help="hotspot water levels in ft")
    ap.add_argument("--hotspots", type=int, default=5, help="how many hotspot drill-downs to render")
    a = ap.parse_args()
    from playwright.sync_api import sync_playwright

    page_path = Path(a.page).resolve()
    out = ROOT / "renders" / a.tag
    if out.exists():
        shutil.rmtree(out)
    (out / "_vid").mkdir(parents=True)
    srv = serve(page_path.parent, a.port)
    frames = []
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--use-gl=swiftshader", "--enable-webgl", "--ignore-gpu-blocklist"])
        ctx = b.new_context(viewport={"width": 1280, "height": 800}, record_video_dir=str(out / "_vid"),
                            record_video_size={"width": 1280, "height": 800})
        pg = ctx.new_page()
        errors = []
        pg.on("pageerror", lambda e: errors.append(str(e)))
        pg.route("**/fonts.g*/**", lambda r: r.abort())
        pg.goto(f"http://127.0.0.1:{a.port}/{page_path.name}", wait_until="domcontentloaded")
        pg.wait_for_selector("#sceneLoading", state="detached", timeout=60000)

        for i in range(4):
            btn = pg.locator(f"#sc{i}")
            if not btn.count():
                break
            btn.evaluate("el=>el.click()")
            time.sleep(3.0)  # let the water animate to level and the camera orbit
            f = f"ferry_s{i}.png"
            shot(pg, "#scene", str(out / f))
            frames.append({"file": f, "scene": "ferry_building", "scenario": btn.inner_text().strip(),
                           "readout": text(pg, "#scene .readout"), "hud": text(pg, "#scene .hud")})

        presets = pg.locator("#hotList button")
        n = presets.count()
        for k in range(min(n, a.hotspots)):
            presets.nth(k).evaluate("el=>el.click()")
            time.sleep(4.0)  # lidar decode + fill
            name = f"rank{presets.nth(k).locator('b').first.inner_text().strip().lstrip('#')}"
            for ft in a.levels.split(","):
                pg.eval_on_selector("#hsDepth", "(el,v)=>{el.value=v;el.dispatchEvent(new Event('input',{bubbles:true}))}", ft)
                time.sleep(1.5)
                f = f"hs_{name}_{ft}ft.png"
                shot(pg, "#hsScene", str(out / f))
                frames.append({"file": f, "scene": name, "title": text(pg, "#hotList button[aria-pressed=true]"), "water_ft_above_lowest": float(ft),
                               "readout": text(pg, "#hsScene .readout"), "hud": text(pg, "#hsHud")})
        vid = pg.video.path() if pg.video else None
        ctx.close(); b.close()
    srv.shutdown()

    if vid and Path(vid).exists():
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", vid, "-vf", "scale=1280:-2",
                        "-c:v", "libx264", "-crf", "28", "-an", str(out / "orbit.mp4")], check=False)
    shutil.rmtree(out / "_vid", ignore_errors=True)

    try:
        from PIL import Image
        ims = [Image.open(out / f["file"]).convert("RGB") for f in frames]
        if ims:
            w = 400; cols = 4
            th = [im.resize((w, int(im.height * w / im.width))) for im in ims]
            h = max(t.height for t in th); rows = (len(th) + cols - 1) // cols
            sheet = Image.new("RGB", (cols * w, rows * h), (10, 16, 22))
            for i, t in enumerate(th):
                sheet.paste(t, ((i % cols) * w, (i // cols) * h))
            sheet.save(out / "contact.png", optimize=True)
    except Exception as e:
        print("contact sheet skipped:", e)

    manifest = {"tag": a.tag, "page": str(page_path.relative_to(ROOT)) if ROOT in page_path.parents else str(page_path),
                "rendered_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "frames": frames,
                "video": "orbit.mp4" if (out / "orbit.mp4").exists() else None, "page_errors": errors}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"{len(frames)} frames, video={'yes' if manifest['video'] else 'no'}, page errors={len(errors)} -> {out}")


if __name__ == "__main__":
    main()
