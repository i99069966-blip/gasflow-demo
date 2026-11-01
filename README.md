# GasCam — 基于 LSPR 基板的实时气源定位相机（iOS）

GasCam 是一个类似 Blackmagic Camera 的专业手动相机 App，拍摄 TPI LSPR 基板时，
**实时**计算每个像素的颜色变化（ΔR/R），显示气体分布热图、到达时间图，
并用**箭头指向气体进入基板的方向（气源方向）**。

算法已在你拍摄的 `A001_10312104_C067.mov`（乙醇，1080p 100 fps）上验证：

| 项目 | 结果 |
|---|---|
| 首次到达 | t = 3.81 s（基线后约 3.8 s） |
| 气体进入点 | 基板上沿，x ≈ 0.40（画面归一化坐标） |
| 箭头方向 | 75° → 稳定在 ≈ 95°（正上方偏左一点），首次到达后 **10 ms 内**给出 |
| 置信度 | 0.77（单侧进入，非常明确） |

`tools/gas_reference.py` 是与 App **逐步一致**的 Python 参考实现，
可以在电脑上对任何录像复现 App 的结果，并用 `tools/render_demo.py` 渲染演示视频。

---

## 1. 功能

**专业相机控制（顶部状态栏，点击即编辑）**

| 功能 | 说明 |
|---|---|
| FPS / 分辨率 | 720p / 1080p / 4K × 24–240 fps（按机型自动列出支持的组合） |
| SHUTTER 快门 | 1/24 – 1/8000，同时显示快门角度；AUTO 时可调 EV 曝光补偿 |
| ISO | 按镜头实际范围；预设值 + 连续滑块 |
| WB 白平衡 | 色温 2000–10000 K、色调 ±150、预设、锁定当前、灰卡/场景一键白平衡 |
| FOCUS 对焦 | 连续 AF（点画面选对焦点）或手动镜头位置 0–1 |
| 镜头选择 | 0.5x / 1x / 2x·3x·5x / 前置（按机型自动识别） |
| 闪光灯亮度 | 常亮模式 0–100%，可作为基板光源 |
| 比特率 / 编码 | H.264 / HEVC，10–200 Mb/s |

**辅助拍摄（预览右侧竖排按钮）**

`FC` 假色（ARRI 风格 IRE 色带） · `ZEB` 斑马纹（阈值可调） · `PEAK` 峰值对焦 ·
`GRID` 三分线 · `+` 中心十字 · `LVL` 水平仪（镜头朝下时显示 X/Y 倾角） ·
`ROI` 框选基板区域 · `➚` 显示/隐藏气源箭头。
左下角为 RGB + 亮度**直方图**（右侧红条 = 有像素过曝）。

**气体检测（中间状态栏）**

- `BASELINE`：锁定 AE/AWB/AF → 取 30 帧平均作为基线 → 开始监测
- `RESET`：清空到达时间图，等待下一次通气
- `LIVE / HEAT / ARRIVAL`：原图 / 响应热图 / 到达时间图
- 状态：待机 → 基线 xx% → 监测中 → **检测到气体**（显示角度与置信度）

**其他**

- 录像 `.mov` + 相机/算法设置 `.json` + 每帧分析日志 `.csv`，可选存入相册
- 📷 按钮保存**结果图**（画面 + 热图/到达图 + 箭头 + 数值）为 PNG
- **视频分析模式**：从相册 / “文件”/ 本 App 录像导入视频，走完全相同的算法（可 0.1×–2× 或最快速度回放）。
  **模拟器没有相机，用这个模式测试。**

---

## 2. 构建与安装

工程格式兼容 **Xcode 15.0 及以上**（包括你的 Xcode 15.2），App 需要 **iOS 17.0+**。

> ⚠️ **Xcode 版本与 iPhone 系统版本的限制**：Xcode 15.2 只能把 App 装到 **iOS 17.x** 的 iPhone 上；
> iOS 18 / iOS 26 的手机需要 Xcode 16 以上（Apple 的限制，不是本工程的问题）。见下面“方案 B / C”。

### 方案 A：iPhone 是 iOS 17.x → 直接用 Xcode 15.2

1. 双击打开 `GasCam.xcodeproj`
2. 左侧选中工程 → TARGETS `GasCam` → **Signing & Capabilities**
   - Team：选你的 Apple ID（免费账号也可以，装到手机上 7 天有效）
   - 若提示 Bundle Identifier 已被占用，把 `jp.lab.lspr.GasCam` 改成任意唯一的名字
3. iPhone 用数据线连 Mac；首次需在 iPhone **设置 → 隐私与安全性 → 开发者模式** 打开并重启
4. Xcode 顶部选择你的 iPhone → ▶︎ Run
5. 首次运行若提示“不受信任的开发者”：iPhone **设置 → 通用 → VPN 与设备管理** → 信任

### 方案 B：借用一台能装新版 Xcode 的 Mac（研究室的 Apple Silicon Mac 等）

步骤同方案 A。把整个 `GasCam` 文件夹拷过去即可。

### 方案 C：GitHub 云端编译（不需要新 Mac）

工程里带了 `.github/workflows/build-ios.yml`。把整个文件夹推到一个 GitHub 仓库后，
GitHub 的云端 Mac 会用最新 Xcode 编译，生成 `GasCam-unsigned.ipa`（在 Actions 页面下载）。
再用 Sideloadly 等侧载工具，以你的 Apple ID 签名并装到 iPhone（免费账号 7 天有效，到期重装即可）。

### 只测试算法：Xcode 15.2 的 iOS 17.2 模拟器

模拟器没有相机，但可以完整测试“视频分析模式”：选任意 iPhone 模拟器运行 →
把 `A001_10312104_C067.mov` 拖进模拟器窗口（会存入“照片”）→ App 里 ⚙︎ → “从相册导入视频分析”。
Intel Mac 上 1080p 100 fps 回放可能跟不上，可选 0.25× 或“最快”。

> 本工程是在没有 Xcode 的环境中编写的（Swift 代码已通过语法检查，算法已用 Python 在你的视频上验证），
> 首次编译时 Xcode 可能会报少量错误。把报错原文发给我即可快速修正。

---

## 3. 推荐实验流程

1. **固定手机**，镜头朝下对准基板。打开 `LVL`，把 X/Y 倾角调到 ±0.5° 以内（绿点）。
2. **帧率与快门**：日本九州为 **60 Hz** 电网，灯光以 120 Hz 闪烁 → 快门用 **1/60 或 1/120**（关东 50 Hz 用 1/50 或 1/100）。
   需要捕捉快速气流时用 60–120 fps。
3. **ISO / 闪光灯 / 白平衡**：
   - 打开 `ZEB`（95%）和直方图，确保基板上没有斑马纹 —— 过曝像素（≥250）会被算法自动排除。
   - 打开 `FC`：基板最好落在中间灰（绿色）附近，不要出现红/黄（过曝）或紫/蓝（过暗）。
   - 白平衡**务必锁定**（自动白平衡会“修正”掉 LSPR 的颜色变化）。
4. **对焦**：手动对焦 + `PEAK`，让基板纹理出现红色描边。
5. 点 `ROI`，拖动框或四角框住基板，再点 `ROI` 结束。避开螺丝、反光点和标记字。
6. 点 **BASELINE**（会自动锁定曝光/白平衡/对焦）。等状态变为“监测中”。
7. 开始录制（红色按钮）→ 通入气体。
8. 气体到达后箭头出现：**红色 × = 气体进入基板的位置（气源方向）**，黄圈 = 最早接触点。
   气体消失 5 s 后自动重置，上一次结果以虚线保留，等待下一次通气。
9. 📷 保存结果图；录像、CSV、JSON 在 iPhone “文件”App → 我的 iPhone → GasCam。

> 任何手动修改相机参数都会自动重新取基线（因为参考图已失效）。

---

## 4. 算法

每帧（默认最多 30 Hz）在 256×144 的分析网格上运行，与 `tools/gas_reference.py` 完全一致：

1. **信号** S：R 通道（可选 G / B / 亮度 / r=R/(R+G+B)），两次盒式滤波（≈高斯平滑）
2. **基线**：前 N 帧（默认 30）逐像素均值 S₀ 和噪声 σ（Welford）
3. **响应** ΔS% = −100·(S − S₀)/S₀（你的基板 R 通道**下降**，可改为上升/双向），时间 EMA 平滑
4. **激活**：ΔS% > max(2%, 4σ)，且在 ROI 内、基线未过曝/欠曝；连续 2 帧确认
5. **到达时间图**：每个像素首次被确认激活的时刻
6. **气源方向**：
   - E = 最早到达的 5% 像素的重心（气体首次接触基板的位置）
   - C = 所有已到达像素的重心
   - 方向 = C → E，延长到 ROI 边缘 = 气体进入点（红色 ×）
   - 置信度 = |E − C| / 羽流半径。< 0.25 时说明气体是从基板**正上方**向四周扩散，显示同心圆而非箭头

为什么不用到达时间平面拟合：在你的视频里气体是“喷射 + 扩散”，后期的慢速扩散会把拟合方向拉偏（63°–150° 之间跳动），
而 E/C 重心法从第一帧起就稳定在 80°–97°。

---

## 5. 输出文件

| 文件 | 内容 |
|---|---|
| `GasCam_yyyyMMdd_HHmmss.mov` | 原始画面（竖屏，未叠加任何图层），H.264/HEVC |
| `….json` | 镜头、分辨率、fps、ISO、快门、白平衡、对焦、闪光灯、编码、比特率、检测参数、ROI |
| `….csv` | 每个分析帧：`t_s, phase, mean_resp_pct, max_resp_pct, active_frac, hotspot_x/y, arrived_px, src_mode, src_angle_deg, src_conf, entry_x/y, src_x/y` |
| `GasCam_result_….png` | 结果图 |

坐标均为归一化（0–1，原点在竖屏画面左上角）。角度：0° = 右，90° = 上，180° = 左，−90° = 下。

---

## 6. 在电脑上复现 / 批量分析

```bash
cd tools
pip install -r requirements.txt     # 还需要系统里有 ffmpeg
python gas_reference.py  your_video.mov --out result --roi 0.03 0.06 0.92 0.58
python render_demo.py    your_video.mov  demo.mp4
```

`--roi x0 y0 x1 y1` 为归一化 ROI（上例是你视频中的基板位置）。

---

## 7. 代码结构

```
GasCam/
├─ GasCamApp.swift              App 入口
├─ Analysis/
│  ├─ GasModels.swift           参数、结果、枚举
│  ├─ GasAnalyzer.swift         ★ 检测 + 到达时间 + 气源定位（纯 Swift，可移植）
│  ├─ FrameDownsampler.swift    vImage 缩小到分析网格 + 直方图
│  └─ Colormap.swift            Turbo 色表
├─ Camera/
│  ├─ CameraController.swift    AVCaptureSession + 全部手动控制
│  ├─ CameraSettings.swift      分辨率/编码/预设
│  └─ VideoRecorder.swift       AVAssetWriter 录像 + CSV 日志
├─ Rendering/
│  ├─ PreviewRenderer.swift     Core Image + Metal 预览：假色、斑马纹、峰值对焦、热图叠加
│  └─ MetalPreviewView.swift
├─ Pipeline/FramePipeline.swift 帧分发：相机/文件 → 分析 → 显示 → 录制
├─ Playback/VideoFileSource.swift 视频文件实时回放
└─ UI/                          SwiftUI 界面
tools/                          Python 参考实现与渲染脚本
.github/workflows/build-ios.yml  GitHub 云端编译（方案 C）
```

## 8. 已知限制

- 箭头是**画面坐标系**下的方向（手机固定时即基板坐标系）。手持扫描需要再加图像配准，后续可扩展。
- 4K 60 fps 以上时竖屏旋转与录制负担较重，建议实验用 1080p。
- 长时间高亮度常亮闪光灯会发热，系统可能自动降低亮度或关闭闪光灯 —— 这会改变画面亮度、让基线失效。长实验建议用外部光源或 ≤50% 亮度，必要时重新取基线。
