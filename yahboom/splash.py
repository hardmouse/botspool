import time
from PIL import Image, ImageDraw, ImageFont
from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306

serial = i2c(port=7, address=0x3C)
device = ssd1306(serial, width=128, height=32)

img = Image.new("1", device.size)
draw = ImageDraw.Draw(img)
font = ImageFont.load_default()

draw.text((0, 0), "JETSON BOOTING...", font=font, fill=255)
draw.text((0, 10), "Please wait", font=font, fill=255)
device.display(img)

# Keep it visible for a bit, then exit
time.sleep(8)
