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
    face_sock.sendto(name.encode(), FACE_ADDR)

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
        while True:
            k = get_key()

            if k:
                k = k.lower()

                if k == "q":
                    send("S")
                    break

                # ---- Servo scan controls ----
                if k == "z":
                    set_face("scan")
                    send("Z")   # start/resume scan
                elif k == "c":
                    set_face("idle")
                    send("X")   # stop scan, HOLD position

                if k == " ":
                    left = right = 0
                    send("S")

                if k == "t":
                    auto = not auto
                    left = right = 0
                    send("S")
                    print("\nAUTO =", auto)

                if not auto:
                    if k == "w":
                        left, right = 160, 160
                    elif k == "s":
                        left, right = -160, -160
                    elif k == "a":
                        left, right = -120, 120
                    elif k == "d":
                        left, right = 120, -120
                    elif k == "x":
                        left, right = 0, 0

            now = time.time()
            if now - last_send > 0.2:
                last_send = now
                if auto:
                    send("S")
                else:
                    if left == 0 and right == 0:
                        send("S")
                    else:
                        send("M {} {}".format(left, right))

    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
        ser.close()

if __name__ == "__main__":
    main()
