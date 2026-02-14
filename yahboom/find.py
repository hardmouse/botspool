import glob
from smbus2 import SMBus

TARGET_ADDRS = [0x3C, 0x3D]

def probe(busnum: int, addr: int) -> bool:
    try:
        with SMBus(busnum) as bus:
            bus.read_byte(addr)
        return True
    except OSError:
        return False

buses = sorted(int(p.split("-")[-1]) for p in glob.glob("/dev/i2c-*"))

found = []
for b in buses:
    for a in TARGET_ADDRS:
        if probe(b, a):
            found.append((b, a))

if not found:
    print("No OLED found at 0x3C/0x3D on any /dev/i2c-* bus.")
else:
    for b, a in found:
        print(f"FOUND: bus={b} addr=0x{a:02X}")
