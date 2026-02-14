import socket
import subprocess
import os
import signal
import time

BASE = os.path.dirname(os.path.abspath(__file__))
FACE_DIR = os.path.join(BASE, "faces")
DEFAULT_FACE = "idle"
UDP_PORT = 5005

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", UDP_PORT))

current = None
proc = None  # current fbi process

def kill_current():
    global proc
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=0.5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    proc = None

def show(face):
    global current, proc
    face = face.strip()
    if not face or face == current:
        return

    path = os.path.join(FACE_DIR, f"{face}.png")
    if not os.path.exists(path):
        print(f"[face] missing: {path}")
        return

    kill_current()

    # NOTE: face.py is run with sudo, so DO NOT put sudo here.
    proc = subprocess.Popen(
        ["fbi", "-T", "1", "-a", "-noverbose", path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    current = face
    print("[face] ->", current)

def cleanup(*_):
    kill_current()
    raise SystemExit

signal.signal(signal.SIGINT, cleanup)
signal.signal(signal.SIGTERM, cleanup)

print("[face] UI running (fbi mode)")
show(DEFAULT_FACE)

while True:
    data, _ = sock.recvfrom(1024)
    msg = data.decode("utf-8").strip()

    if msg == "__QUIT__":
        print("[face] quitting")
        cleanup()

    show(msg)
