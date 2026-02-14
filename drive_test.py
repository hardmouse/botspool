import serial
import time

PORT = "/dev/serial0"
BAUD = 115200

ser = serial.Serial(PORT, BAUD, timeout=1)
time.sleep(2)

def send(cmd):
  ser.write((cmd + "\n").encode())
  print("sent:", cmd)

send("S")
time.sleep(1)

send("F")
time.sleep(1)

send("L")
time.sleep(1)

send("R")
time.sleep(1)

send("B")
time.sleep(2)

sned("S")
time.sleep(2)

sned("M 120 120")
time.sleep(2)

send("M 80 200")
time.sleep(2)

sned("S")
