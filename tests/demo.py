"""Persistent manual acceptance fixture; launch in a disposable Rex pane."""
import sys
import termios
import tty

lines = [
    "Rex Fastcopy demo | Ctrl+S then f",
    "",
    "IPv4:   192.0.2.10       198.51.100.20",
    "Path:   /tmp/rex-fastcopy/demo.txt",
    "Git:    deadbeef         Date: 2026-10-30",
    "Words:  hello world      中文测试",
    "UUID:   123e4567-e89b-12d3-a456-426614174000",
    "",
    "Type red labels to copy. Tab: multi-select. Esc: cancel.",
    "This original pane should remain unchanged after copying.",
]
old = termios.tcgetattr(sys.stdin)
try:
    tty.setraw(sys.stdin)
    sys.stdout.write("\x1b[2J\x1b[H" + "\r\n".join(lines))
    sys.stdout.flush()
    while sys.stdin.read(1) != "q":
        pass
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
