#!/usr/bin/env python3
import time
from PIL import Image, ImageDraw, ImageFont
from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306, sh1106, ssd1309

I2C_PORT = 7
I2C_ADDR = 0x3C

CANDIDATES = [
    ("ssd1306 128x64", ssd1306, 128, 64),
    ("ssd1306 128x32", ssd1306, 128, 32),
    ("ssd1309 128x64", ssd1309, 128, 64),
    ("ssd1309 128x32", ssd1309, 128, 32),
    ("sh1106  128x64", sh1106,  128, 64),
    ("sh1106  128x32", sh1106,  128, 32),
]

def show(dev, label):
    w, h = dev.size
    img = Image.new("1", (w, h))
    d = ImageDraw.Draw(img)
    f = ImageFont.load_default()

    # Strong visual pattern to detect corruption
    d.rectangle((0, 0, w-1, h-1), outline=255, fill=0)
    d.line((0, 0, w-1, h-1), fill=255)
    d.line((0, h-1, w-1, 0), fill=255)
    d.text((2, 2), label, font=f, fill=255)

    dev.display(img)

def main():
    serial = i2c(port=I2C_PORT, address=I2C_ADDR)

    for label, cls, w, h in CANDIDATES:
        try:
            dev = cls(serial, width=w, height=h)
            show(dev, label)
            print("SHOWING:", label)
            time.sleep(3)
            dev.clear()
        except Exception as e:
            print("FAILED:", label, "->", e)

if __name__ == "__main__":
    main()
