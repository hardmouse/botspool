#!/usr/bin/env python3
import cv2
import time
import numpy as np
import os

# -----------------------
# Settings
# -----------------------
CAM_INDEX = 0
WIDTH, HEIGHT = 640, 480

# Lower these on Pi B+ if needed
FPS_LIMIT = 10
FACE_EVERY_N_FRAMES = 6
PERSON_EVERY_N_FRAMES = 10

# Motion tuning
MOTION_THRESHOLD = 25
MOTION_MIN_AREA = 2500  # lower => more sensitive

# Haar face cascade path (your Pi)
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

# -----------------------
# Validate Haar file
# -----------------------
if not os.path.exists(HAAR_FACE):
    raise RuntimeError(f"Haar cascade not found: {HAAR_FACE}")

# -----------------------
# Init camera
# -----------------------
cap = cv2.VideoCapture(CAM_INDEX)
if not cap.isOpened():
    raise RuntimeError(f"Could not open /dev/video{CAM_INDEX}")

cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)

# -----------------------
# Detectors
# -----------------------
face_cascade = cv2.CascadeClassifier(HAAR_FACE)
if face_cascade.empty():
    raise RuntimeError(f"Could not load Haar cascade: {HAAR_FACE}")

hog = cv2.HOGDescriptor()
hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())

# Motion state
prev_gray = None

# Cached results
faces = []
persons = []
motion_boxes = []

frame_i = 0
last_time = time.time()

print("Overlay mode: GREEN=motion, BLUE=face, RED=person. Press Q or ESC to quit.")

while True:
    last_time = clamp_fps(last_time, FPS_LIMIT)

    ok, frame = cap.read()
    if not ok or frame is None:
        time.sleep(0.1)
        continue

    frame_i += 1

    # Resize for consistency
    frame = cv2.resize(frame, (WIDTH, HEIGHT), interpolation=cv2.INTER_AREA)

    # Convert to gray for motion/face
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    gray_blur = cv2.GaussianBlur(gray, (7, 7), 0)

    # -----------------------
    # Motion detection (every frame)
    # -----------------------
    motion_boxes = []
    if prev_gray is None:
        prev_gray = gray_blur
    else:
        diff = cv2.absdiff(prev_gray, gray_blur)
        _, thresh = cv2.threshold(diff, MOTION_THRESHOLD, 255, cv2.THRESH_BINARY)
        thresh = cv2.dilate(thresh, None, iterations=2)

        contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for c in contours:
            area = cv2.contourArea(c)
            if area < MOTION_MIN_AREA:
                continue
            x, y, w, h = cv2.boundingRect(c)
            motion_boxes.append((x, y, w, h))

        prev_gray = gray_blur

    # -----------------------
    # Face detection (every N frames)
    # -----------------------
    if frame_i % FACE_EVERY_N_FRAMES == 0:
        faces = face_cascade.detectMultiScale(
            gray,
            scaleFactor=1.1,
            minNeighbors=5,
            minSize=(40, 40),
        )

    # -----------------------
    # Person detection (every N frames)
    # -----------------------
    if frame_i % PERSON_EVERY_N_FRAMES == 0:
        rects, _weights = hog.detectMultiScale(
            frame,
            winStride=(8, 8),
            padding=(8, 8),
            scale=1.05
        )
        persons = rects

    # -----------------------
    # Draw overlays
    # -----------------------
    # GREEN = motion
    for (x, y, w, h) in motion_boxes:
        cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 255, 0), 2)
        cv2.putText(frame, "MOTION", (x, max(0, y - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)

    # BLUE = face
    for (x, y, w, h) in faces:
        cv2.rectangle(frame, (x, y), (x + w, y + h), (255, 0, 0), 2)
        cv2.putText(frame, "FACE", (x, max(0, y - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 0, 0), 2)

    # RED = person
    for (x, y, w, h) in persons:
        cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 0, 255), 2)
        cv2.putText(frame, "PERSON", (x, max(0, y - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)

    # FPS display
    cv2.putText(frame, f"frame {frame_i}", (10, 20),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)

    cv2.imshow("detect_3_overlay", frame)

    key = cv2.waitKey(1) & 0xFF
    if key in (27, ord('q'), ord('Q')):
        break

cap.release()
cv2.destroyAllWindows()
