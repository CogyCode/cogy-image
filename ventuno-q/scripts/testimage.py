"""Generated test screenshots for the self-tests. Standard library only.

A PNG of a small app window with a red error banner and a blue button, with
their text drawn in a built-in pixel font, so the tests need no image library
or fonts on the board. The self-tests check that the model reads both texts
back, without a caption: the text must come from the image.

    python3 testimage.py out.png [--banner TEXT] [--button TEXT] [--width W] [--height H]
"""

import argparse
import struct
import zlib

# 5 x 7 glyphs, one string of 5 bits per row, top to bottom. Text is drawn in
# upper case.
GLYPHS = {
    "A": "01110 10001 10001 11111 10001 10001 10001",
    "B": "11110 10001 10001 11110 10001 10001 11110",
    "C": "01110 10001 10000 10000 10000 10001 01110",
    "D": "11110 10001 10001 10001 10001 10001 11110",
    "E": "11111 10000 10000 11110 10000 10000 11111",
    "F": "11111 10000 10000 11110 10000 10000 10000",
    "G": "01110 10001 10000 10111 10001 10001 01111",
    "H": "10001 10001 10001 11111 10001 10001 10001",
    "I": "01110 00100 00100 00100 00100 00100 01110",
    "J": "00111 00010 00010 00010 00010 10010 01100",
    "K": "10001 10010 10100 11000 10100 10010 10001",
    "L": "10000 10000 10000 10000 10000 10000 11111",
    "M": "10001 11011 10101 10101 10001 10001 10001",
    "N": "10001 10001 11001 10101 10011 10001 10001",
    "O": "01110 10001 10001 10001 10001 10001 01110",
    "P": "11110 10001 10001 11110 10000 10000 10000",
    "Q": "01110 10001 10001 10001 10101 10010 01101",
    "R": "11110 10001 10001 11110 10100 10010 10001",
    "S": "01111 10000 10000 01110 00001 00001 11110",
    "T": "11111 00100 00100 00100 00100 00100 00100",
    "U": "10001 10001 10001 10001 10001 10001 01110",
    "V": "10001 10001 10001 10001 10001 01010 00100",
    "W": "10001 10001 10001 10101 10101 10101 01010",
    "X": "10001 10001 01010 00100 01010 10001 10001",
    "Y": "10001 10001 01010 00100 00100 00100 00100",
    "Z": "11111 00001 00010 00100 01000 10000 11111",
    "0": "01110 10001 10011 10101 11001 10001 01110",
    "1": "00100 01100 00100 00100 00100 00100 01110",
    "2": "01110 10001 00001 00010 00100 01000 11111",
    "3": "11111 00010 00100 00010 00001 10001 01110",
    "4": "00010 00110 01010 10010 11111 00010 00010",
    "5": "11111 10000 11110 00001 00001 10001 01110",
    "6": "00110 01000 10000 11110 10001 10001 01110",
    "7": "11111 00001 00010 00100 01000 01000 01000",
    "8": "01110 10001 10001 01110 10001 10001 01110",
    "9": "01110 10001 10001 01111 00001 00010 01100",
    " ": "00000 00000 00000 00000 00000 00000 00000",
    ".": "00000 00000 00000 00000 00000 01100 01100",
    ":": "00000 01100 01100 00000 01100 01100 00000",
    "-": "00000 00000 00000 11111 00000 00000 00000",
    "@": "01110 10001 10111 10101 10111 10000 01110",
}

WHITE, BLACK, GREY, DIM = (255, 255, 255), (0, 0, 0), (220, 220, 220), (105, 105, 105)
RED, BLUE = (178, 34, 34), (65, 105, 225)


class Canvas:
    def __init__(self, width, height, color=WHITE):
        self.width, self.height = width, height
        row = bytes(color) * width
        self.rows = [bytearray(row) for _ in range(height)]

    def rect(self, x, y, w, h, color):
        x0, x1 = max(0, x), min(self.width, x + w)
        if x1 <= x0:
            return
        fill = bytes(color) * (x1 - x0)
        for r in range(max(0, y), min(self.height, y + h)):
            self.rows[r][x0 * 3:x1 * 3] = fill

    def outline(self, x, y, w, h, color):
        for rx, ry, rw, rh in ((x, y, w, 2), (x, y + h - 2, w, 2), (x, y, 2, h), (x + w - 2, y, 2, h)):
            self.rect(rx, ry, rw, rh, color)

    def text(self, x, y, text, color, scale):
        """Draws text with its top left corner at (x, y). Each glyph is
        5 x 7 pixels times scale, with one pixel column of spacing."""
        for ch in text.upper():
            for r, bits in enumerate(GLYPHS.get(ch, GLYPHS[" "]).split()):
                for c, bit in enumerate(bits):
                    if bit == "1":
                        self.rect(x + c * scale, y + r * scale, scale, scale, color)
            x += 6 * scale

    def png(self):
        raw = b"".join(b"\x00" + bytes(row) for row in self.rows)

        def chunk(kind, data):
            return (struct.pack(">I", len(data)) + kind + data +
                    struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
        return (b"\x89PNG\r\n\x1a\n" +
                chunk(b"IHDR", struct.pack(">IIBBBBB", self.width, self.height, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def screenshot(banner="Payment failed", button="Save changes", width=800, height=500):
    """The test screenshot as PNG bytes. Layout scales with the width, so a
    large screenshot has the same proportions as a small one."""
    k = max(1, width // 800)
    c = Canvas(width, height)
    c.rect(0, 0, width, 40 * k, GREY)
    c.text(12 * k, 10 * k, "Account settings", BLACK, 3 * k)
    c.rect(40 * k, 70 * k, width - 80 * k, 60 * k, RED)
    c.text(56 * k, 83 * k, banner, WHITE, 5 * k)
    c.text(40 * k, 160 * k, "Email", BLACK, 3 * k)
    c.outline(40 * k, 190 * k, width - 80 * k, 36 * k, DIM)
    c.text(48 * k, 199 * k, "owner@example.com", DIM, 3 * k)
    c.rect(40 * k, 260 * k, 260 * k, 48 * k, BLUE)
    c.text(56 * k, 274 * k, button, WHITE, 3 * k)
    return c.png()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out")
    ap.add_argument("--banner", default="Payment failed")
    ap.add_argument("--button", default="Save changes")
    ap.add_argument("--width", type=int, default=800)
    ap.add_argument("--height", type=int, default=500)
    a = ap.parse_args(argv)
    with open(a.out, "wb") as f:
        f.write(screenshot(a.banner, a.button, a.width, a.height))


if __name__ == "__main__":
    main()
