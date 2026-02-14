import time
import serial
import cv2

PORT="/dev/serial0"
BAUD=115200

ser = serial.Serial(PORT, BAUD, timeout=0)
cap = cv2.VideoCapture(0)

def send(cmd):
    ser.write((cmd + "\n").encode("utf-8"))

def main():
    if not cap.isOpened():
        print("Camera not found on /dev/video0")
        return

    print("AUTO mode: ESC quits. Robot should be on stands first.")
    send("S")
    time.sleep(1)

    last = time.time()
    while True:
        ret, frame = cap.read()
        if not ret:
            send("S")
            continue

        # simple “obstacle” heuristic:
        # look at center region brightness (dark = close object / wall)
        h, w = frame.shape[:2]
        cx1, cx2 = int(w*0.4), int(w*0.6)
        cy1, cy2 = int(h*0.4), int(h*0.7)
        roi = frame[cy1:cy2, cx1:cx2]

        gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
        avg = gray.mean()

        # show debug window (optional)
        cv2.rectangle(frame, (cx1, cy1), (cx2, cy2), (0,255,0), 2)
        cv2.putText(frame, "avg=%.1f" % avg, (10,30),
                    cv2.FONT_HERSHEY_SIMPLEX, 1, (255,255,255), 2)
        cv2.imshow("auto", frame)

        key = cv2.waitKey(1) & 0xFF
        if key == 27:  # ESC
            send("S")
            break

        # control decision
        now = time.time()
        if now - last > 0.2:
            last = now
            if avg < 70:       # too dark -> likely close obstacle
                send("M -120 120")  # turn left
            else:
                send("M 140 140")   # forward

    cap.release()
    cv2.destroyAllWindows()
    ser.close()

if __name__ == "__main__":
    main()
