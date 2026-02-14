import subprocess
import os
import sys
import time
import runpy

BASE = os.path.dirname(os.path.abspath(__file__))

def main():
    face_path = os.path.join(BASE, "robot_ui", "face.py")
    teleop_path = os.path.join(BASE, "teleop.py")

    # Start face in background; disconnect from this SSH stdin/out
    subprocess.Popen(
        ["sudo", sys.executable, face_path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    time.sleep(0.3)

    # Run teleop in THIS process (best keyboard reliability)
    runpy.run_path(teleop_path, run_name="__main__")

if __name__ == "__main__":
    main()
