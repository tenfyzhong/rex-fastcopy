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
    def run_selection(self, keys, text="192.0.2.1 192.0.2.2", restore_focus=False, background=False,
                      expect_focus=True, reveal=None, wait_for_snapshot=False):
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "snapshot"
            copied = Path(directory) / "copied"
            if not wait_for_snapshot:
                snapshot.write_text(text)
            extra = ["--wait-for-snapshot"] if wait_for_snapshot else []
            if restore_focus:
                fake_rex = Path(directory) / "rex"
                focus_log = Path(directory) / "focus"
                fake_rex.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{focus_log}"\n')
                fake_rex.chmod(0o700)
                extra += ["--rex", str(fake_rex), "--session", "s", "--pane", "source"]
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
                if wait_for_snapshot:
                    readable, _, _ = select.select([master], [], [], 0.15)
                    self.assertFalse(readable, "picker should not draw before the snapshot is ready")
                    staged = snapshot.with_suffix(".staged")
                    staged.write_text(text)
                    staged.replace(snapshot)
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
                if reveal:
                    self.assertNotIn(reveal, output)
                os.write(master, keys)
                # A real terminal drains repaints while the user types. Keep the
                # PTY reader active too, otherwise a full frame can fill its buffer.
                deadline = time.monotonic() + 5
                while process.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            output += os.read(master, 65536)
                        except OSError:
                            break
                self.assertEqual(process.wait(timeout=1), 0)
                if reveal:
                    self.assertIn(reveal, output)
                if restore_focus:
                    if expect_focus:
                        self.assertEqual(focus_log.read_text().splitlines(),
                                         ["--autostart=false", "focus", "-s", "s", "source"])
                    else:
                        self.assertFalse(focus_log.exists(), "focus loss must not steal focus back")
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

    def test_scroll_reveals_last_row_when_overlay_is_shorter(self):
        text = "first row\n" + "\n" * 11 + "last row: 192.0.2.1"
        self.assertEqual(self.run_selection(b"\x1b[Ba", text, reveal=b"last row: "), "192.0.2.1")

    def test_picker_waits_for_the_native_pane_before_drawing(self):
        self.assertEqual(self.run_selection(b"a", wait_for_snapshot=True), "192.0.2.1")


if __name__ == "__main__":
    unittest.main()
