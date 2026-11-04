"""Frame-difference (FLOW) visualisation, same maths as the app's FLOW mode.

flow(t) = response(t) - response(t - lag)      (response = -100·(R-R0)/R0, EMA-smoothed)
red  = R dropping now  (gas concentration increasing)
blue = R recovering    (gas leaving)

usage: python render_flow.py video.mov out.mp4 [--lag 0.2] [--scale 3] [--roi x0 y0 x1 y1]
"""
import argparse, os, subprocess, sys
import numpy as np, cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gas_reference import GasAnalyzer, decode, W, H

ap = argparse.ArgumentParser()
ap.add_argument("video"); ap.add_argument("out")
ap.add_argument("--lag", type=float, default=0.2)
ap.add_argument("--scale", type=float, default=3.0)
ap.add_argument("--roi", nargs=4, type=float, default=[0.03, 0.07, 0.92, 0.60])
args = ap.parse_args()

frames, times = decode(args.video)
g = GasAnalyzer(roi=tuple(args.roi))
VW, VH = 540, 960
fps = 1 / np.diff(times).mean()
dec = subprocess.Popen(["ffmpeg", "-v", "error", "-i", args.video, "-vf", f"scale={VW}:{VH}", "-vsync", "0",
                        "-f", "rawvideo", "-pix_fmt", "bgr24", "-"], stdout=subprocess.PIPE)
OW, OH = VW * 2, VH
enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{OW}x{OH}",
                        "-r", "50", "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart", args.out], stdin=subprocess.PIPE)
hist = []          # (t, resp copy)
x0, y0, x1, y1 = args.roi
rx0, ry0, rx1, ry1 = int(x0 * VW), int(y0 * VH), int(x1 * VW), int(y1 * VH)
ts_t, ts_r, ts_f = [], [], []
FONT = cv2.FONT_HERSHEY_SIMPLEX
snaps = {}

def flow_rgb(fl, valid, scale):
    v = np.clip(fl / scale, -1, 1)
    a = np.clip((np.abs(v) - 0.15) / 0.3, 0, 1) * valid
    col = np.zeros(fl.shape + (3,), np.float32)
    col[..., 2] = (v > 0) * 255; col[..., 1] = (v > 0) * 60 * (1 - np.abs(v))
    col[..., 0] = (v < 0) * 255; col[..., 1] += (v < 0) * 120 * (1 - np.abs(v))
    return col, np.minimum(1, np.abs(v) * 1.3) * a

for i, (small, t) in enumerate(zip(frames, times)):
    raw = dec.stdout.read(VW * VH * 3)
    if len(raw) < VW * VH * 3: break
    img = np.frombuffer(raw, np.uint8).reshape(VH, VW, 3).astype(np.float32)
    g.process(small, t)
    left = img.copy(); heat = img * 0.35
    fl = None
    if g.ready:
        hist.append((t, g.resp.copy()))
        while hist and t - hist[0][0] > args.lag + 0.5 / fps: hist.pop(0)
        past = hist[0][1]
        fl = g.resp - past
        valid = cv2.resize(g.valid.astype(np.float32), (VW, VH), interpolation=cv2.INTER_NEAREST)
        col, a = flow_rgb(cv2.resize(fl, (VW, VH)), valid, args.scale)
        left = img * (1 - 0.8 * a[..., None]) + col * 0.8 * a[..., None]
        v = np.clip(cv2.resize(np.clip(g.resp, 0, None), (VW, VH)) / 8, 0, 1)
        hc = cv2.applyColorMap((v * 255).astype(np.uint8), cv2.COLORMAP_TURBO).astype(np.float32)
        al = (np.clip(v * 1.4, 0, 0.85) * valid)[..., None]
        heat = img * (1 - al) + hc * al
        m = g.valid
        ts_t.append(t); ts_r.append(float(small[..., 0][m].mean())); ts_f.append(float(g.resp[m].mean()))
    left = left.astype(np.uint8); heat = heat.astype(np.uint8)
    for im in (left, heat): cv2.rectangle(im, (rx0, ry0), (rx1, ry1), (255, 255, 255), 1)
    cv2.rectangle(left, (0, 0), (VW, 34), (0, 0, 0), -1)
    cv2.putText(left, f"FLOW (frame diff, lag {args.lag:.2f}s)  t={t:5.2f}s", (8, 24), FONT, 0.6, (255, 255, 255), 2, cv2.LINE_AA)
    cv2.putText(left, "red: R dropping (gas in)   blue: recovering", (8, int(VH * 0.62 + 28)), FONT, 0.55, (255, 255, 255), 2, cv2.LINE_AA)
    # right: heat (top crop) + R curve
    right = np.full((OH, VW, 3), 24, np.uint8)
    crop = heat[: int(VH * 0.64)]
    ch = int(crop.shape[0] * 0.75); cw = int(VW * 0.75)
    right[40:40 + ch, (VW - cw) // 2:(VW - cw) // 2 + cw] = cv2.resize(crop, (cw, ch))
    cv2.putText(right, "HEAT (vs baseline, -dR/R up to 8%)", (12, 28), FONT, 0.6, (230, 230, 230), 1, cv2.LINE_AA)
    gy0, gy1, gx0, gx1 = 40 + ch + 50, OH - 50, 60, VW - 20
    cv2.putText(right, "ROI mean R (raw)", (12, gy0 - 12), FONT, 0.6, (230, 230, 230), 1, cv2.LINE_AA)
    cv2.rectangle(right, (gx0, gy0), (gx1, gy1), (90, 90, 90), 1)
    if len(ts_t) > 1:
        lo, hi = min(ts_r) - 0.5, max(ts_r) + 0.5
        tmax = times[-1]
        for k in range(3):
            vv = lo + (hi - lo) * k / 2; yy = int(gy1 - (vv - lo) / (hi - lo) * (gy1 - gy0))
            cv2.putText(right, f"{vv:.1f}", (8, yy + 4), FONT, 0.4, (180, 180, 180), 1, cv2.LINE_AA)
        pts = np.array([[gx0 + tt / tmax * (gx1 - gx0), gy1 - (r - lo) / (hi - lo) * (gy1 - gy0)] for tt, r in zip(ts_t, ts_r)], np.int32)
        cv2.polylines(right, [pts], False, (80, 90, 255), 2, cv2.LINE_AA)
        for s in range(0, int(tmax) + 1, 2):
            xx = int(gx0 + s / tmax * (gx1 - gx0))
            cv2.putText(right, f"{s}s", (xx - 8, gy1 + 18), FONT, 0.4, (180, 180, 180), 1, cv2.LINE_AA)
    out = np.hstack([left, right])
    enc.stdin.write(out.tobytes())
    for st in (3.85, 4.2, 4.6, 5.0, 6.0, 7.0, 8.5, 9.0):
        if abs(t - st) < 0.006: snaps[st] = left[: int(VH * 0.64)].copy()
enc.stdin.close(); enc.wait(); dec.wait()
if snaps:
    ks = sorted(snaps)
    tiles = []
    for k in ks:
        im = cv2.resize(snaps[k], (270, int(270 * snaps[k].shape[0] / VW)))
        cv2.rectangle(im, (0, 0), (70, 22), (0, 0, 0), -1)
        cv2.putText(im, f"{k:.2f}s", (4, 16), FONT, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
        tiles.append(im)
    rows = [np.hstack(tiles[i:i + 4]) for i in range(0, len(tiles), 4) if len(tiles[i:i + 4]) == 4]
    cv2.imwrite(args.out.replace(".mp4", "_frames.png"), np.vstack(rows))
print("done")
