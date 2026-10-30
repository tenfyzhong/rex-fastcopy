"""Exercise the actual terminal program through a PTY, without touching clipboard."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/debug/rex-fastcopy"


class TerminalTests(unittest.TestCase):
    def run_selection(self, keys, text="192.0.2.1 192.0.2.2", restore_focus=False, background=False, expect_focus=True):
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "snapshot"
            copied = Path(directory) / "copied"
            snapshot.write_text(text)
            extra = []
            if restore_focus:
                fake_rex = Path(directory) / "rex"
                focus_log = Path(directory) / "focus"
                fake_rex.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{focus_log}"\n')
                fake_rex.chmod(0o700)
                extra = ["--rex", str(fake_rex), "--session", "s", "--pane", "source"]
            if background:
                neighbor = Path(directory) / "neighbor"
                neighbor.write_text("NEIGHBOR-STAYS-LEFT")
                extra += ["--region", "0.5,0,0.5,1", "--background", f"0,0,0.5,1:{neighbor}"]
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 80, 0, 0))
            process = subprocess.Popen(
                [str(BINARY), "--snapshot", str(snapshot), "--action", f"/usr/bin/tee {copied}"] + extra,
                stdin=slave, stdout=slave, stderr=slave,
            )
            os.close(slave)
            try:
                output = b""
                deadline = time.monotonic() + 5
                ready = b"\x1b[1;41H" if background else b"\x1b[48;2;30;30;46m"
                while ready not in output and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        output += os.read(master, 65536)
                self.assertIn(b"\x1b[2J", output, output.decode(errors="replace"))
                self.assertIn(b"\x1b[48;2;30;30;46m", output,
                              "overlay must paint an opaque background over the original pane")
                self.assertFalse(snapshot.exists(), "snapshot must be unlinked before interaction")
                if background:
                    self.assertIn(b"NEIGHBOR-STAYS-LEFT", output)
                    self.assertIn(b"\x1b[1;41H", output)
                    self.assertFalse(neighbor.exists())
                os.write(master, keys)
                # A real terminal drains repaints while the user types. Keep the
                # PTY reader active too, otherwise a full frame can fill its buffer.
                deadline = time.monotonic() + 5
                while process.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            os.read(master, 65536)
                        except OSError:
                            break
                self.assertEqual(process.wait(timeout=1), 0)
                if restore_focus and not expect_focus:
                    self.assertFalse(focus_log.exists(), "focus loss must not steal focus back")
                elif restore_focus:
                    self.assertEqual(focus_log.read_text().splitlines(),
                                     ["--autostart=false", "focus", "-s", "s", "source"])
                return copied.read_text() if copied.exists() else None
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)

    def test_right_selection_keeps_neighbor_visible(self):
        self.assertEqual(self.run_selection(b"a", background=True), "192.0.2.1")

    def test_focus_loss_cancels_without_stealing_focus(self):
        self.assertIsNone(self.run_selection(b"\x1b[O", restore_focus=True, expect_focus=False))

    def test_single_select(self):
        self.assertEqual(self.run_selection(b"a"), "192.0.2.1")

    def test_multi_select(self):
        self.assertEqual(self.run_selection(b"\tab\r"), "192.0.2.1 192.0.2.2")

    def test_escape_cancels(self):
        self.assertIsNone(self.run_selection(b"\x1b"))

    def test_control_c_cancels(self):
        self.assertIsNone(self.run_selection(b"\x03"))

    def test_empty_screen_can_cancel(self):
        self.assertIsNone(self.run_selection(b"\x1b", ""))

    def test_focus_returns_on_selection(self):
        self.assertEqual(self.run_selection(b"a", restore_focus=True), "192.0.2.1")

    def test_focus_returns_on_cancel(self):
        self.assertIsNone(self.run_selection(b"\x1b", restore_focus=True))


if __name__ == "__main__":
    unittest.main()
