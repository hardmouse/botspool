import sys, time
import serial
import termios, tty, select
import socket

PORT = "/dev/serial0"
BAUD = 115200
ser = serial.Serial(PORT, BAUD, timeout=0)

face_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
FACE_ADDR = ("127.0.0.1", 5005)

def set_face(name):
    try:
        face_sock.sendto(name.encode(), FACE_ADDR)
    except OSError:
        pass

def send(cmd):
    ser.write((cmd + "\n").encode("utf-8"))

def get_key(timeout=0.05):
    r, _, _ = select.select([sys.stdin], [], [], timeout)
    if r:
        return sys.stdin.read(1)
    return None

def main():
    print("WASD drive | SPACE stop | T toggle auto | Q quit")
    print("Servo scan: Z start/resume | C stop (hold)")
    print("Manual starts ON. Keep robot lifted for first test.")

    old = termios.tcgetattr(sys.stdin)
    tty.setcbreak(sys.stdin.fileno())

    auto = False
    last_send = time.time()
    left = 0
    right = 0

    try:
        send("S")
        set_face("idle")

        while True:
            k = get_key()

            if k:
                k = k.lower()
                print(f"[key] {repr(k)}", flush=True)

                if k == "q":
                    send("S")
                    set_face("idle")
                    break

                # ---- Servo scan controls ----
                if k == "z":
                    set_face("scan")
                    send("Z")
                    print("[uart] Z (start scan)", flush=True)
                    continue

                # STOP scan (hold) — allow BOTH c and x to stop scan
                if k in ("c", "v"):   # you can use v as an extra stop key if you want
                    set_face("idle")
                    send("X")
                    print("[uart] X (stop scan hold)", flush=True)
                    continue

                # ---- Stop controls ----
                if k == " ":
                    left = right = 0
                    send("S")
                    set_face("idle")
                    print("[uart] S (stop)", flush=True)
                    continue

                if k == "t":
                    auto = not auto
                    left = right = 0
                    send("S")
                    set_face("idle")
                    print("\nAUTO =", auto, flush=True)
                    continue

                if not auto:
                    if k == "w":
                        left, right = 160, 160
                        set_face("happy")
                    elif k == "s":
                        left, right = -160, -160
                        set_face("angry")
                    elif k == "a":
                        left, right = -120, 120
                        set_face("happy")
                    elif k == "d":
                        left, right = 120, -120
                        set_face("happy")
                    elif k == "x":
                        left, right = 0, 0
                        send("S")
                        set_face("idle")
                        print("[uart] S (stop)", flush=True)

            # keep ESP32 failsafe happy
            now = time.time()
            if now - last_send > 0.2:
                last_send = now
                if auto:
                    send("S")
                else:
                    if left == 0 and right == 0:
                        send("S")
                    else:
                        cmd = f"M {left} {right}"
                        send(cmd)

    finally:
        # always restore terminal and stop everything
        try:
            send("S")
        except Exception:
            pass

        try:
            set_face("idle")
            set_face("__QUIT__")   # <-- this cleanly shuts down face.py
        except Exception:
            pass

        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
        ser.close()

if __name__ == "__main__":
    main()
