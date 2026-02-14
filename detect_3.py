#!/usr/bin/env python3
import cv2
import time
import numpy as np
import os

# -----------------------
# Settings (tune these)
# -----------------------
CAM_INDEX = 0

# Lower these if Pi is slow:
WIDTH, HEIGHT = 640, 480
FPS_LIMIT = 10

# Run heavier detectors less often to save CPU
FACE_EVERY_N_FRAMES = 6
PERSON_EVERY_N_FRAMES = 10

# Motion detection sensitivity
MOTION_THRESHOLD = 25       # pixel-diff threshold (lower = more sensitive)
MOTION_MIN_AREA = 2500      # min moving area (lower = more sensitive)

# Haar cascade path (you found this)
HAAR_FACE = "/usr/share/opencv4/haarcascades/haarcascade_frontalface_default.xml"

# -----------------------
# Helpers
# -----------------------
def clamp_fps(last_time: float, fps_limit: int) -> float:
    if fps_limit <= 0:
        return time.time()
    min_dt = 1.0 / fps_limit
    now = time.time()
    dt = now - last_time
    if dt < min_dt:
        time.sleep(min_dt - dt)
        now = time.time()
    return now

def yesno(x: bool) -> str:
    return "YES" if x else "no"

# -----------------------
# Validate Haar file
# -----------------------
if not os.path.exists(HAAR_FACE):
    raise RuntimeError(
        f"Haar cascade not found at: {HAAR_FACE}\n"
        f"Try: sudo find /usr -name haarcascade_frontalface_default.xml 2>/dev/null"
    )

# -----------------------
# Init camera
# -----------------------
cap = cv2.VideoCapture(CAM_INDEX)
if not cap.isOpened():
    raise RuntimeError(f"Could not open camera /dev/video{CAM_INDEX}")

cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)

# -----------------------
# Face detector (Haar)
# -----------------------
face_cascade = cv2.CascadeClassifier(HAAR_FACE)
if face_cascade.empty():
    raise RuntimeError(f"Could not load Haar cascade: {HAAR_FACE}")

# -----------------------
# Person detector (HOG)
# -----------------------
hog = cv2.HOGDescriptor()
hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())

# -----------------------
# Motion detector state
# -----------------------
prev_gray = None
motion_now = False

# Cached outputs (updated every N frames)
faces_count = 0
persons_count = 0

frame_i = 0
last_print = 0.0
PRINT_EVERY_SEC = 0.25

print("Running Motion + Face + Person detection (headless). Ctrl+C to stop.")
print(f"Camera: /dev/video{CAM_INDEX}  Size: {WIDTH}x{HEIGHT}  FPS limit: {FPS_LIMIT}")
print(f"Haar: {HAAR_FACE}\n")

last_time = time.time()

try:
    while True:
        last_time = clamp_fps(last_time, FPS_LIMIT)

        ok, frame = cap.read()
        if not ok or frame is None:
            print("\nNo frame read. Retrying...")
            time.sleep(0.2)
            continue

        frame_i += 1

        # Resize for consistent CPU usage
        frame_small = cv2.resize(frame, (WIDTH, HEIGHT), interpolation=cv2.INTER_AREA)
        gray = cv2.cvtColor(frame_small, cv2.COLOR_BGR2GRAY)
        gray_blur = cv2.GaussianBlur(gray, (7, 7), 0)

        # -------- Motion detection --------
        if prev_gray is None:
            prev_gray = gray_blur
            motion_now = False
        else:
            diff = cv2.absdiff(prev_gray, gray_blur)
            _, thresh = cv2.threshold(diff, MOTION_THRESHOLD, 255, cv2.THRESH_BINARY)
            thresh = cv2.dilate(thresh, None, iterations=2)

            contours, _ = cv2.findContours(
                thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
            )

            motion_now = any(cv2.contourArea(c) >= MOTION_MIN_AREA for c in contours)
            prev_gray = gray_blur

        # -------- Face detection --------
        if frame_i % FACE_EVERY_N_FRAMES == 0:
            faces = face_cascade.detectMultiScale(
                gray,
                scaleFactor=1.1,
                minNeighbors=5,
                minSize=(40, 40),
            )
            faces_count = int(len(faces))

        # -------- Person detection --------
        if frame_i % PERSON_EVERY_N_FRAMES == 0:
            rects, _weights = hog.detectMultiScale(
                frame_small,
                winStride=(8, 8),
                padding=(8, 8),
                scale=1.05,
            )
            persons_count = int(len(rects))

        # -------- Print indicator --------
        now = time.time()
        if now - last_print >= PRINT_EVERY_SEC:
            last_print = now
            line = (
                f"MOTION={yesno(motion_now):<3}  "
                f"FACES={faces_count:<2}  "
                f"PERSONS={persons_count:<2}  "
                f"(frame={frame_i})"
            )
            print("\r" + line + " " * 10, end="", flush=True)

except KeyboardInterrupt:
    print("\nStopped.")

finally:
    cap.release()
