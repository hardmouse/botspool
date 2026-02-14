import cv2
import time

cap = cv2.VideoCapture("/dev/video0", cv2.CAP_V4L2)

# Use a very safe resolution first
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

time.sleep(0.5)

ok, frame = cap.read()
cap.release()

if not ok:
    print("No frame")
else:
    cv2.imwrite("frame.jpg", frame)
    print("Saved frame.jpg", frame.shape)
