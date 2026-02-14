#!/usr/bin/env python3
import time
import subprocess
from PIL import Image, ImageDraw, ImageFont

from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306

# ---------- OLED CONFIG ----------
I2C_PORT = 7
I2C_ADDR = 0x3C
WIDTH = 128
HEIGHT = 32
# -------------------------------

# ---------- SCROLL / TIMING ----------
LINE = 11            # 8px rows = crisp on SSD1306 "pages"
SCROLL_STEP = 1      # pixels per tick
SCROLL_EVERY = 0.3   # seconds per scroll tick (0.05 = fast)
FRAME_SLEEP = 0.3    # render loop sleep (0.02 = ~50 FPS)
STATS_EVERY = 1.0    # update system stats every 1 second
# -------------------------------------

serial = i2c(port=I2C_PORT, address=I2C_ADDR)
device = ssd1306(serial, width=WIDTH, height=HEIGHT)
device.contrast(255)

width, height = device.size
font = ImageFont.load_default()

def run(cmd: str) -> str:
    return subprocess.check_output(cmd, shell=True, text=True).strip()

def jetson_temp() -> str:
    for p in (
        "/sys/class/thermal/thermal_zone0/temp",
        "/sys/devices/virtual/thermal/thermal_zone0/temp",
    ):
        try:
            v = int(open(p).read().strip())
            return f"T:{v/1000:.0f}C"
        except Exception:
            pass
    return "T:--"

def get_ip() -> str:
    try:
        ip = run("hostname -I | awk '{print $1}'")
        return ip if ip else "--"
    except Exception:
        return "--"

def cpu_percent_nonblocking(prev=None):
    parts = open("/proc/stat").readline().split()[1:]
    vals = list(map(int, parts))
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    total = sum(vals)

    if prev is None:
        return 0, (total, idle)

    pt, pi = prev
    dt = total - pt
    di = idle - pi
    pct = int(((dt - di) * 100) / dt) if dt > 0 else 0
    return pct, (total, idle)

# --- splash (runs once at startup) ---
img = Image.new("1", (width, height), 0)
d = ImageDraw.Draw(img)
d.text((0, 0), "JETSON BOOTING...", font=font, fill=255)
d.text((0, 16), "OLED ONLINE", font=font, fill=255)
device.display(img)
time.sleep(1.5)
# ------------------------------------

# Cached stats (start with placeholders)
CPU = "CPU:--%"
TEMP = "T:--"
MEM = "RAM:--/--"
DISK = "D:--/--"
IP = "--"
CLOCK = "--:--:--"

# CPU baseline
_, cpu_prev = cpu_percent_nonblocking(None)

# Scroll state
scroll_y = 0
last_scroll = time.time()
last_stats = 0.0

# Prebuilt page (will be updated on STATS_EVERY)
page = Image.new("1", (width, height), 0)
page_h = height

def build_page():
    """Build a tall image containing all lines to scroll."""
    global page, page_h

    lines = [
        f"{CPU}   {TEMP}",
        MEM,
        DISK,
        "IP:" + IP,
        CLOCK,
    ]

    page_h = max(height, LINE * len(lines))
    page = Image.new("1", (width, page_h), 0)
    pd = ImageDraw.Draw(page)

    for i, txt in enumerate(lines):
        pd.text((0, i * LINE), txt, font=font, fill=255)

# Build initial page
build_page()

while True:
    now = time.time()

    # --- Update stats on a timer (no blocking sleeps) ---
    if now - last_stats >= STATS_EVERY:
        last_stats = now

        pct, cpu_prev = cpu_percent_nonblocking(cpu_prev)
        CPU = f"CPU:{pct:02d}%"
        TEMP = jetson_temp()
        MEM = run("free -m | awk 'NR==2{printf \"RAM:%d/%d\", $3,$2}'")
        DISK = run("df -m / | awk 'NR==2{printf \"D:%d/%d\", $3,$2}'")
        IP = get_ip()
        CLOCK = time.strftime("%H:%M:%S")

        # Rebuild page only when data changes (fast scrolling)
        build_page()

    # --- Scroll timing ---
    if now - last_scroll >= SCROLL_EVERY:
        last_scroll = now
        scroll_y += SCROLL_STEP
        if scroll_y >= page_h:
            scroll_y = 0

    # --- Crop with wrap-around ---
    y0 = scroll_y
    y1 = y0 + height

    if y1 <= page_h:
        view = page.crop((0, y0, width, y1))
    else:
        view = Image.new("1", (width, height), 0)
        part1 = page.crop((0, y0, width, page_h))
        view.paste(part1, (0, 0))
        rem = height - (page_h - y0)
        part2 = page.crop((0, 0, width, rem))
        view.paste(part2, (0, page_h - y0))

    device.display(view)
    time.sleep(FRAME_SLEEP)
