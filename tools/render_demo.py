"""Render the analyzer output on the recorded video: heat map + arrival map + arrow."""
import subprocess, sys, numpy as np, cv2
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from gas_reference import GasAnalyzer, decode, W, H

SRC = sys.argv[1]
OUT = sys.argv[2]
VW, VH = 540, 960
frames, times = decode(SRC)
g = GasAnalyzer()

dec = subprocess.Popen(["ffmpeg", "-v", "error", "-i", SRC, "-vf", f"scale={VW}:{VH}", "-vsync", "0",
                        "-f", "rawvideo", "-pix_fmt", "bgr24", "-"], stdout=subprocess.PIPE)
OW, OH = VW * 2, VH
enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{OW}x{OH}",
                        "-r", "50", "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart", OUT], stdin=subprocess.PIPE)

x0, y0, x1, y1 = g.roi
rx0, ry0, rx1, ry1 = int(x0 * VW), int(y0 * VH), int(x1 * VW), int(y1 * VH)
series_t, series_v = [], []
FONT = cv2.FONT_HERSHEY_SIMPLEX
snap = None


def turbo(v):
    return cv2.applyColorMap(np.clip(v * 255, 0, 255).astype(np.uint8), cv2.COLORMAP_TURBO)


def draw_arrow(img, r, sx_scale, sy_scale, ox=0, oy=0, thick=4):
    cx, cy = int(ox + r["cx"] * sx_scale), int(oy + r["cy"] * sy_scale)
    sx, sy = int(ox + r["sx"] * sx_scale), int(oy + r["sy"] * sy_scale)
    ex, ey = int(ox + r["ex"] * sx_scale), int(oy + r["ey"] * sy_scale)
    if r["mode"] == "direction":
        cv2.arrowedLine(img, (cx, cy), (sx, sy), (0, 0, 0), thick + 4, cv2.LINE_AA, tipLength=0.18)
        cv2.arrowedLine(img, (cx, cy), (sx, sy), (255, 255, 255), thick, cv2.LINE_AA, tipLength=0.18)
    cv2.circle(img, (ex, ey), 7, (0, 0, 0), 4, cv2.LINE_AA)
    cv2.circle(img, (ex, ey), 7, (0, 255, 255), 2, cv2.LINE_AA)
    cv2.drawMarker(img, (sx, sy), (0, 0, 255), cv2.MARKER_TILTED_CROSS, 22, 3, cv2.LINE_AA)


for i, (small, t) in enumerate(zip(frames, times)):
    raw = dec.stdout.read(VW * VH * 3)
    if len(raw) < VW * VH * 3:
        break
    img = np.frombuffer(raw, np.uint8).reshape(VH, VW, 3).copy()
    r = g.process(small, t)
    left = img.copy()
    if g.ready:
        resp = cv2.resize(np.clip(g.resp, 0, None), (VW, VH), interpolation=cv2.INTER_LINEAR)
        valid = cv2.resize(g.valid.astype(np.uint8), (VW, VH), interpolation=cv2.INTER_NEAREST).astype(bool)
        v = np.clip(resp / g.display_max_pct, 0, 1)
        col = turbo(v)
        a = (np.clip(v * 1.4, 0, 0.75) * valid)[..., None]
        left = (img * (1 - a) + col * a).astype(np.uint8)
        roi_vals = g.resp[g.valid]
        series_t.append(t); series_v.append(float(roi_vals.mean()))
    cv2.rectangle(left, (rx0, ry0), (rx1, ry1), (255, 255, 255), 1)
    if r:
        draw_arrow(left, r, VW, VH)
    # header
    cv2.rectangle(left, (0, 0), (VW, 34), (0, 0, 0), -1)
    status = "BASELINE..." if not g.ready else ("GAS DETECTED" if r else "MONITORING")
    cv2.putText(left, f"t={t:5.2f}s  {status}", (10, 24), FONT, 0.7, (255, 255, 255), 2, cv2.LINE_AA)
    if r:
        cv2.putText(left, f"source dir {r['angle_deg']:.0f} deg  conf {r['conf']:.2f}", (10, int(VH * 0.62 + 30)),
                    FONT, 0.75, (255, 255, 255), 2, cv2.LINE_AA)

    # right panel: arrival map (ROI crop) + time series
    right = np.full((OH, VW, 3), 24, np.uint8)
    cv2.putText(right, "Arrival-time map (ms after first contact)", (12, 28), FONT, 0.6, (230, 230, 230), 1, cv2.LINE_AA)
    if g.ready:
        arr = g.arrival.copy()
        tf = g.t_first if g.t_first is not None else 0
        span = 0.6
        vv = np.clip((arr - tf) / span, 0, 1)
        col = turbo(1 - np.nan_to_num(vv, nan=0))
        col[np.isnan(arr)] = (45, 45, 45)
        col[~g.valid] = (20, 20, 20)
        ax0, ay0, ax1, ay1 = int(x0 * W), int(y0 * H), int(x1 * W), int(y1 * H)
        crop = col[ay0:ay1, ax0:ax1]
        pw = VW - 40
        ph = int(pw * crop.shape[0] / crop.shape[1])
        crop = cv2.resize(crop, (pw, ph), interpolation=cv2.INTER_NEAREST)
        right[44:44 + ph, 20:20 + pw] = crop
        if r:
            rr = dict(r)
            for kx, ky in (("cx", "cy"), ("ex", "ey"), ("sx", "sy")):
                rr[kx] = (r[kx] - x0) / (x1 - x0)
                rr[ky] = (r[ky] - y0) / (y1 - y0)
            draw_arrow(right, rr, pw, ph, 20, 44, 3)
        # colour bar
        by = 44 + ph + 14
        bar = turbo(1 - np.linspace(0, 1, pw)[None, :].repeat(12, 0))
        right[by:by + 12, 20:20 + pw] = bar
        cv2.putText(right, "0", (20, by + 30), FONT, 0.5, (200, 200, 200), 1, cv2.LINE_AA)
        cv2.putText(right, f"{int(span*1000)} ms", (20 + pw - 60, by + 30), FONT, 0.5, (200, 200, 200), 1, cv2.LINE_AA)
        # time series
        gy0, gy1 = by + 70, OH - 60
        gx0, gx1 = 60, VW - 20
        cv2.putText(right, "Mean response in ROI  (-dR/R, %)", (12, gy0 - 14), FONT, 0.6, (230, 230, 230), 1, cv2.LINE_AA)
        cv2.rectangle(right, (gx0, gy0), (gx1, gy1), (90, 90, 90), 1)
        tmax, vmax = times[-1], 6.0
        for gv in (0, 2, 4, 6):
            yy = int(gy1 - gv / vmax * (gy1 - gy0))
            cv2.line(right, (gx0, yy), (gx1, yy), (50, 50, 50), 1)
            cv2.putText(right, f"{gv}", (gx0 - 25, yy + 5), FONT, 0.45, (180, 180, 180), 1, cv2.LINE_AA)
        for gt in range(0, int(tmax) + 1, 2):
            xx = int(gx0 + gt / tmax * (gx1 - gx0))
            cv2.putText(right, f"{gt}s", (xx - 8, gy1 + 20), FONT, 0.45, (180, 180, 180), 1, cv2.LINE_AA)
        if len(series_t) > 1:
            pts = np.array([[gx0 + tt / tmax * (gx1 - gx0), gy1 - min(vv_, vmax) / vmax * (gy1 - gy0)]
                            for tt, vv_ in zip(series_t, series_v)], np.int32)
            cv2.polylines(right, [pts], False, (80, 200, 255), 2, cv2.LINE_AA)
        if g.t_first is not None:
            xx = int(gx0 + g.t_first / tmax * (gx1 - gx0))
            cv2.line(right, (xx, gy0), (xx, gy1), (0, 255, 255), 1)
    cv2.putText(right, "0.5x slow motion  |  GasCam reference algorithm", (12, OH - 18), FONT, 0.5, (150, 150, 150), 1, cv2.LINE_AA)
    out = np.hstack([left, right])
    enc.stdin.write(out.tobytes())
    if abs(t - 4.40) < 0.006:
        snap = out.copy()
    last = out

enc.stdin.close(); enc.wait(); dec.wait()
cv2.imwrite(OUT.replace(".mp4", "_t4.4s.png"), snap if snap is not None else last)
cv2.imwrite(OUT.replace(".mp4", "_final.png"), last)
print("done")
