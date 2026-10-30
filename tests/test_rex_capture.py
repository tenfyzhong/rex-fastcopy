"""Optional integration tests against an installed Rex server.

Run with REX_FASTCOPY_TEST_REX=/absolute/path/to/rex python3 -m unittest
 discover -s tests -p test_rex_capture.py -v. Each test owns a temporary session.
"""
import json
import os
from pathlib import Path
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
REX = os.environ.get("REX_FASTCOPY_TEST_REX")


@unittest.skipUnless(REX, "set REX_FASTCOPY_TEST_REX to test the live Rex API")
class RexCaptureTests(unittest.TestCase):
    def rex(self, *args):
        return json.loads(subprocess.check_output([REX, *args], text=True))

    def check_screen(self, output, expected, paginated=False, overlay=False):
        program = (
            "import sys; "
            "sys.stdout.write('old history\\r\\n' * 40 + '\\x1b[2J\\x1b[H' + "
            + repr(output) + "); sys.stdout.flush(); sys.stdin.read()"
        )
        created = self.rex("new", "fastcopy-capture-test", "--shell=none", "--json",
                           "--", "/usr/bin/python3", "-c", program)
        session = created["session_id"]
        block = created["initial_windows"][0]["block_ids"][0]
        try:
            def capture():
                return self.rex("block", "call", "-s", session, "-b", block,
                                "format", '{"format":"vt"}')["content"]

            deadline = time.monotonic() + 5
            while "old history" not in capture():
                self.assertLess(time.monotonic(), deadline, "fixture did not start")
                time.sleep(0.02)
            before = capture()
            size = self.rex("block", "call", "-s", session, "-b", block, "size")
            # Run production capture against Rex, intercepting only layer creation
            # to inspect the exact snapshot the selector would receive.
            script = r'''
local core = dofile(rex.args.core)
local captured = {}
local api = {
    exec = rex.exec,
    block = {call = function(creator, method, args)
        if method == "format" and rex.args.paginated then args.max_bytes = 32 end
        return rex.block.call(creator, method, args)
    end},
    session = {
        view = rex.session.view,
        new_layer = function(args)
            local command = args.layout.block.options.command
            local file = assert(io.open(command[3]))
            captured.text = file:read("*a")
            file:close()
            if rex.args.overlay then return rex.session.new_layer(args) end
            os.remove(command[3])
            return {layer_id = "test"}
        end,
    },
}
local layer = core.open(api, {session_id = rex.args.session, block_id = rex.args.block},
    {directory = rex.args.directory, args = {"--action", "/usr/bin/true"}})
captured.layer = layer
return captured
'''
            actual = self.rex("do", "-s", session, "-e", script, "--args", json.dumps({
                "core": str(ROOT / "core.lua"), "directory": str(ROOT),
                "session": session, "block": block, "paginated": paginated, "overlay": overlay,
            }), "--json")
            rows = expected.split("\n")
            self.assertEqual("\n".join(line.rstrip(" ") for line in actual["text"].split("\n")),
                             expected + "\n" * (size["rows"] - len(rows)))
            if overlay:
                picker = actual["layer"]["block_ids"][0]
                deadline = time.monotonic() + 5
                while True:
                    frame = self.rex("block", "call", "-s", session, "-b", picker,
                                     "format", '{"format":"text"}')["content"]
                    if ".0.2.1" in frame:
                        break
                    self.assertLess(time.monotonic(), deadline, "selector did not render")
                    time.sleep(0.02)
                self.assertNotIn("old history", frame)
                self.assertTrue(frame.startswith("a92.0.2.1"), frame)
                subprocess.run([REX, "send-key", "-s", session, "-b", picker, "a"],
                               check=True, capture_output=True)
                deadline = time.monotonic() + 5
                while picker in [b["block_id"] for b in self.rex(
                        "block", "ls", "-s", session, "--json")["blocks"]]:
                    self.assertLess(time.monotonic(), deadline, "selection did not close")
                    time.sleep(0.02)
            self.assertEqual(capture(), before, "capture changed the source terminal")
        finally:
            subprocess.run([REX, "kill", session], check=True, capture_output=True)

    def test_half_screen_retains_blank_bottom_rows(self):
        self.check_screen("192.0.2.1\r\nsecond line", "192.0.2.1\nsecond line")

    def test_clear_screen_does_not_reintroduce_history(self):
        self.check_screen("", "")

    def test_colored_erased_cells_do_not_move_text(self):
        self.check_screen(
            "\x1b[41m\x1b[80X\x1b[0m192.0.2.1\x1b[44m\x1b[5X\x1b[0m\x1b[5CGAP",
            "192.0.2.1     GAP",
        )

    def test_real_selector_opens_and_selects_after_colored_erase(self):
        self.check_screen("\x1b[41m\x1b[80X\x1b[0m192.0.2.1", "192.0.2.1", overlay=True)

    def test_paginated_styles_links_and_tabs(self):
        self.check_screen(
            "\x1b[31mRED\x1b[0m\tGAP\x1b]8;;https://example.com\x1b\\"
            "LINK\x1b]8;;\x1b\\", "RED     GAPLINK", paginated=True,
        )


if __name__ == "__main__":
    unittest.main()
