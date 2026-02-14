import cv2
import time

DEVICE = "/dev/video0"
WIDTH = 640
HEIGHT = 480
FPS = 20
DURATION = 10  # seconds

cap = cv2.VideoCapture(DEVICE, cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)
cap.set(cv2.CAP_PROP_FPS, FPS)

fourcc = cv2.VideoWriter_fourcc(*"XVID")
out = cv2.VideoWriter("output.avi", fourcc, FPS, (WIDTH, HEIGHT))

start = time.time()

while time.time() - start < DURATION:
    ok, frame = cap.read()
    if not ok:
        print("Frame grab failed")
        break
    out.write(frame)

cap.release()
out.release()

print("Saved video: output.avi")
