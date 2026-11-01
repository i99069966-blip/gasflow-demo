"""
Reference implementation of the on-device GasAnalyzer (GasCam iOS app).
Mirrors GasAnalyzer.swift step by step so results on recorded video
match what the app shows live.

Usage:
  python gas_reference.py video.mov --out result_dir [--roi x0 y0 x1 y1]
"""
import argparse, json, os, subprocess
import numpy as np

W, H = 144, 256  # analysis grid (portrait 9:16), same as the app


# ---------------------------------------------------------------- helpers
def box_blur(img, r):
    """Box blur with clamped edges via running sums (same as Swift boxBlur)."""
    if r <= 0:
        return img.copy()
    out = img
    for axis in (1, 0):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (r + 1, r)
        p = np.pad(out, pad, mode="edge")
        c = np.cumsum(p, axis=axis, dtype=np.float64)
        n = out.shape[axis]
        if axis == 1:
            out = (c[:, 2 * r + 1:2 * r + 1 + n] - c[:, 0:n]) / (2 * r + 1)
        else:
            out = (c[2 * r + 1:2 * r + 1 + n, :] - c[0:n, :]) / (2 * r + 1)
    return out.astype(np.float32)


def signal_of(rgb, channel):
    R, G, B = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    if channel == "R":
        return R
    if channel == "G":
        return G
    if channel == "B":
        return B
    if channel == "luma":
        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    if channel == "rchroma":  # normalized red chromaticity, x100
        return 100.0 * R / np.maximum(R + G + B, 1.0)
    raise ValueError(channel)


class GasAnalyzer:
    def __init__(self, roi=(0.03, 0.06, 0.92, 0.58), channel="R", polarity=-1,
                 blur_radius=2, baseline_frames=30, ema_alpha=0.5,
                 k_sigma=4.0, min_pct=2.0, confirm_frames=2,
                 min_arrived_frac=0.01, display_max_pct=12.0):
        self.roi = roi
        self.channel, self.polarity = channel, polarity
        self.blur_radius, self.baseline_frames = blur_radius, baseline_frames
        self.ema_alpha, self.k_sigma, self.min_pct = ema_alpha, k_sigma, min_pct
        self.confirm_frames = confirm_frames
        self.min_arrived_frac = min_arrived_frac
        self.display_max_pct = display_max_pct
        yy, xx = np.mgrid[0:H, 0:W]
        x0, y0, x1, y1 = roi
        self.in_roi = (xx >= x0 * W) & (xx < x1 * W) & (yy >= y0 * H) & (yy < y1 * H)
        self.xx, self.yy = xx.astype(np.float64), yy.astype(np.float64)
        self.reset_baseline()

    # -- state
    def reset_baseline(self):
        self.n = 0
        self.mean = np.zeros((H, W), np.float64)
        self.m2 = np.zeros((H, W), np.float64)
        self.max_rgb = np.zeros((H, W), np.float64)
        self.min_rgb = np.full((H, W), 255.0)
        self.ready = False
        self.reset_arrivals()

    def reset_arrivals(self):
        self.resp = np.zeros((H, W), np.float32)
        self.run = np.zeros((H, W), np.int32)
        self.arrival = np.full((H, W), np.nan)
        self.order = []          # pixel indices in arrival order
        self.t_first = None
        self.result = None

    # -- per frame
    def process(self, rgb_u8, t):
        rgb = rgb_u8.astype(np.float32)
        s = box_blur(box_blur(signal_of(rgb, self.channel), self.blur_radius), self.blur_radius)
        if not self.ready:
            self.n += 1
            d = s - self.mean
            self.mean += d / self.n
            self.m2 += d * (s - self.mean)
            self.max_rgb = np.maximum(self.max_rgb, rgb.max(axis=2))
            self.min_rgb = np.minimum(self.min_rgb, rgb.min(axis=2))
            if self.n >= self.baseline_frames:
                var = self.m2 / max(self.n - 1, 1)
                mu = np.maximum(self.mean, 1e-3)
                self.sigma_pct = 100.0 * np.sqrt(var) / mu
                self.thr = np.maximum(self.min_pct, self.k_sigma * self.sigma_pct)
                self.valid = self.in_roi & (self.max_rgb < 250) & (self.min_rgb > 8) & (self.mean > 5)
                self.n_valid = int(self.valid.sum())
                self.ready = True
            return None
        r = self.polarity * 100.0 * (s - self.mean) / np.maximum(self.mean, 1e-3)
        self.resp = (self.ema_alpha * r + (1 - self.ema_alpha) * self.resp).astype(np.float32)
        active = (self.resp > self.thr) & self.valid
        self.run = np.where(active, self.run + 1, 0)
        newly = (self.run == self.confirm_frames) & np.isnan(self.arrival)
        if newly.any():
            if self.t_first is None:
                self.t_first = t
            self.arrival[newly] = t
            idx = np.flatnonzero(newly)
            # stable order within the same frame: row-major (same as Swift loop)
            self.order.extend(idx.tolist())
        self.active_frac = active.sum() / max(self.n_valid, 1)
        self.result = self.estimate_source()
        return self.result

    def estimate_source(self):
        n = len(self.order)
        if n < max(20, self.min_arrived_frac * self.n_valid):
            return None
        idx = np.array(self.order)
        ys, xs = np.divmod(idx, W)
        xs = xs + 0.5                       # pixel centres (same as GasAnalyzer.swift)
        ys = ys + 0.5
        ts = self.arrival.flat[idx]
        # E: centroid of the earliest 5 % (>=10 px, ties at the cut included)
        #    = where the gas first touched the plate
        k = min(n, max(10, int(0.05 * n)))
        tk = ts[k - 1]                      # arrivals are stored in time order
        m = ts <= tk
        ex, ey = xs[m].mean(), ys[m].mean()
        # C: centroid of every pixel the gas has reached so far
        cx, cy = xs.mean(), ys.mean()
        vx, vy = ex - cx, ey - cy
        dist = np.hypot(vx, vy)
        plume_r = np.sqrt(n / np.pi)        # radius of a disc with the plume's area
        conf = dist / plume_r               # 0 = radial spreading, ~1 = one-sided entry
        dx, dy = (vx / dist, vy / dist) if dist > 1e-6 else (0.0, 0.0)
        # extend the ray C -> E upstream to the ROI edge
        x0, y0, x1, y1 = [v * s for v, s in zip(self.roi, (W, H, W, H))]
        tt = []
        for lo, hi, p, d in ((x0, x1, ex, dx), (y0, y1, ey, dy)):
            if d > 1e-9:
                tt.append((hi - p) / d)
            elif d < -1e-9:
                tt.append((lo - p) / d)
        tedge = max(0.0, min(tt)) if tt else 0.0
        sx, sy = ex + dx * tedge, ey + dy * tedge
        mode = "direction" if conf >= 0.25 else "point"
        if mode == "point":
            sx, sy = ex, ey
        return dict(n=n, ex=ex / W, ey=ey / H, cx=cx / W, cy=cy / H, dx=dx, dy=dy,
                    conf=conf, angle_deg=float(np.degrees(np.arctan2(-dy, dx))),
                    sx=sx / W, sy=sy / H, mode=mode, t_first=self.t_first,
                    active_frac=self.active_frac)


# ---------------------------------------------------------------- video io
def decode(path):
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={W}:{H}:flags=area",
           "-vsync", "0", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(-1, H, W, 3)
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "frame=pts_time", "-of", "csv=p=0", path], capture_output=True, text=True).stdout
    t = np.array([float(x.strip(",")) for x in out.split() if x.strip(",")])[:len(a)]
    return a, t


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--out", default="result")
    ap.add_argument("--roi", nargs=4, type=float, default=[0.03, 0.06, 0.92, 0.58])
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    frames, times = decode(args.video)
    g = GasAnalyzer(roi=tuple(args.roi))
    log = []
    for f, t in zip(frames, times):
        r = g.process(f, t)
        if r:
            log.append(dict(t=float(t), **{k: (float(v) if v is not None and not isinstance(v, str) else v) for k, v in r.items()}))
    with open(os.path.join(args.out, "source_log.json"), "w") as fh:
        json.dump(log, fh, indent=1)
    if log:
        last = log[-1]
        print("first arrival t=%.2fs, final angle=%.1f deg, conf=%.2f, mode=%s, source edge point=(%.2f, %.2f)"
              % (last["t_first"], last["angle_deg"], last["conf"], last["mode"], last["sx"], last["sy"]))
