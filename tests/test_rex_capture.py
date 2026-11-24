"""Optional integration tests against an installed Rex server.

Run with REX_FASTCOPY_TEST_REX=/absolute/path/to/rex python3 -m unittest
 discover -s tests -p test_rex_capture.py -v. Each test owns a temporary session.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
REX = os.environ.get("REX_FASTCOPY_TEST_REX")


@unittest.skipUnless(REX, "set REX_FASTCOPY_TEST_REX to test the live Rex API")
class RexCaptureTests(unittest.TestCase):
    def rex(self, *args):
        return json.loads(subprocess.check_output([REX, *args], text=True))

    def check_screen(self, output, expected, paginated=False, overlay=False, zoomed=False,
                     action="/usr/bin/true", action_ready=None):
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
            if zoomed:
                subprocess.run([REX, "zoom", "-s", session, "-b", block, "--on"],
                               check=True, capture_output=True)

            def capture():
                return self.rex("block", "call", "-s", session, "-b", block,
                                "format", '{"format":"vt"}')["content"]

            deadline = time.monotonic() + 5
            while "old history" not in capture():
                self.assertLess(time.monotonic(), deadline, "fixture did not start")
                time.sleep(0.02)
            before = capture()
            size = self.rex("block", "call", "-s", session, "-b", block, "size")
            # Inspect the exact snapshot passed to the picker before it starts.
            script = r'''
local core = dofile(rex.args.core)
local captured = {}
local function capture_snapshot(options)
    local path = (options.command[3]:gsub("%.ready$", ""))
    local file = assert(io.open(path))
    captured.text = file:read("*a")
    file:close()
    return path
end
local api = {
    call = rex.call,
    exec = rex.exec,
    json = rex.json,
    block = {call = function(creator, method, args)
        if method == "format" and rex.args.paginated then args.max_bytes = 32 end
        return rex.block.call(creator, method, args)
    end},
    session = {
        view = rex.session.view,
        new_layer = function(args)
            os.remove(capture_snapshot(args.layout.block.options))
            return {layer_id = "test"}
        end,
        new_block = function(args)
            capture_snapshot(args.options)
            return rex.session.new_block(args)
        end,
    },
}
local layer = core.open(api, {session_id = rex.args.session, block_id = rex.args.block},
    {directory = rex.args.directory, rex_path = rex.args.rex_path,
        args = {"--action", rex.args.action}})
captured.layer = layer
return captured
'''
            args = {
                "core": str(ROOT / "lua/rex-fastcopy/core.lua"), "directory": str(ROOT),
                "session": session, "block": block, "paginated": paginated,
                "overlay": overlay, "action": action,
            }
            if overlay:
                args["rex_path"] = REX
            actual = self.rex("do", "-s", session, "-e", script, "--args", json.dumps(args), "--json")
            rows = expected.split("\n")
            self.assertEqual("\n".join(line.rstrip(" ") for line in actual["text"].split("\n")),
                             expected + "\n" * (size["rows"] - len(rows)))
            if overlay:
                picker = actual["layer"]["block_ids"][0]
                source = created["initial_windows"][0]["window_id"]
                deadline = time.monotonic() + 5
                while True:
                    frame = self.rex("block", "call", "-s", session, "-b", picker,
                                     "format", '{"format":"text"}')["content"]
                    view = self.rex("api", "call", "-s", session, "session.view")
                    if ".0.2.1" in frame and view["windows"][0]["focused_block_id"] == picker:
                        break
                    self.assertLess(time.monotonic(), deadline, "selector did not render")
                    time.sleep(0.02)
                self.assertNotIn("old history", frame)
                self.assertTrue(frame.startswith("a92.0.2.1"), frame)
                self.assertEqual([w["window_id"] for w in view["windows"]], [source])
                self.assertEqual(view["active_window_id"], source)
                self.assertEqual(view["windows"][0]["layers"][0]["layout"]["block_id"], picker)
                if zoomed:
                    self.assertEqual(view["windows"][0]["zoomed_block_id"], picker)
                picker_size = self.rex("block", "call", "-s", session, "-b", picker, "size")
                for axis in ("columns", "rows"):
                    self.assertEqual(picker_size[axis], size[axis])
                subprocess.run([REX, "send-key", "-s", session, "-b", picker, "a"],
                               check=True, capture_output=True)
                if action_ready is not None:
                    deadline = time.monotonic() + 5
                    while not action_ready.exists():
                        self.assertLess(time.monotonic(), deadline, "selection action did not start")
                        time.sleep(0.02)
                    selected_frame = self.rex("block", "call", "-s", session, "-b", picker,
                                              "format", '{"format":"text"}')["content"]
                    self.assertEqual(selected_frame, frame, "picker blanked before the pane was restored")
                deadline = time.monotonic() + 5
                while picker in [b["block_id"] for b in self.rex(
                        "block", "ls", "-s", session, "--json")["blocks"]]:
                    self.assertLess(time.monotonic(), deadline, "selection did not close")
                    time.sleep(0.02)
                view = self.rex("api", "call", "-s", session, "session.view")
                self.assertEqual([w["window_id"] for w in view["windows"]], [source])
                self.assertEqual(view["active_window_id"], source)
                self.assertEqual(view["windows"][0]["focused_block_id"], block)
                if zoomed:
                    self.assertEqual(view["windows"][0]["zoomed_block_id"], block)
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

    def test_zoomed_picker_restores_zoom_after_selection(self):
        self.check_screen("192.0.2.1", "192.0.2.1", overlay=True, zoomed=True)

    def test_picker_keeps_its_frame_until_source_is_restored(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / "action-started"
            action = shlex.join(["/usr/bin/python3", "-c",
                                 "from pathlib import Path; import sys, time; "
                                 "Path(sys.argv[1]).touch(); time.sleep(2)", str(ready)])
            self.check_screen("192.0.2.1", "192.0.2.1", overlay=True, action=action, action_ready=ready)

    def test_four_pane_picker_restores_native_grid_and_shell_eof(self):
        def terminal(text):
            return ("/usr/bin/python3", "-c", "import sys; print("
                    + repr(text) + ", flush=True); sys.stdin.read()")

        created = self.rex("new", "fastcopy-split-test", "--shell=none", "--json",
                           "--", *terminal("neighbor 192.0.2.2"))
        session = created["session_id"]
        source = created["initial_windows"][0]["window_id"]
        left = created["initial_windows"][0]["block_ids"][0]
        try:
            right = self.rex("split", "-s", session, "-b", left, "--split=right",
                             "--shell=none", "--json", "--", *terminal("upper-right"))["block_ids"][0]
            bottom_left = self.rex("split", "-s", session, "-b", left, "--split=below",
                                   "--shell=none", "--json", "--", *terminal("lower-left"))["block_ids"][0]
            target = self.rex("split", "-s", session, "-b", right, "--split=below",
                              "--shell=none", "--json", "--", *terminal("192.0.2.1"))["block_ids"][0]

            def frame(block):
                return self.rex("block", "call", "-s", session, "-b", block,
                                "format", '{"format":"text"}')["content"]

            def source_window():
                view = self.rex("api", "call", "-s", session, "session.view")
                self.assertEqual([w["window_id"] for w in view["windows"]], [source])
                self.assertEqual(view["active_window_id"], source)
                return view["windows"][0]

            def wait_for(check, on_failure=lambda: None):
                deadline = time.monotonic() + 5
                while not check():
                    if time.monotonic() >= deadline:
                        self.fail(f"timed out waiting for Rex: {on_failure()}")
                    time.sleep(0.02)

            wait_for(lambda: "192.0.2.2" in frame(left) and "192.0.2.1" in frame(target))
            original_layer, = source_window()["layers"]
            target_rect = original_layer["layout"]["split"]["after"]["split"]["after"]["rect"]
            original_size = self.rex("block", "call", "-s", session, "-b", target, "size")
            original_pid = self.rex("block", "call", "-s", session, "-b", target, "process")["child"]["pid"]
            script = """
local core = dofile(rex.args.core)
return core.open(rex, {session_id = rex.args.session, block_id = rex.args.block},
    {directory = rex.args.directory, rex_path = rex.args.rex_path, args = {"--action", "/usr/bin/true"}})
"""
            picker = self.rex("do", "-s", session, "-e", script, "--args", json.dumps({
                "core": str(ROOT / "lua/rex-fastcopy/core.lua"), "directory": str(ROOT),
                "rex_path": REX, "session": session, "block": target,
            }), "--json")
            selectable, = picker["block_ids"]
            wait_for(lambda: frame(selectable).startswith("a92.0.2.1"))
            wait_for(lambda: source_window()["focused_block_id"] == selectable)
            window = source_window()
            self.assertEqual(len(window["layers"]), 1, "Fastcopy must not show a floating layer")
            tiled, = window["layers"]
            native_pane = tiled["layout"]["split"]["after"]["split"]["after"]
            self.assertEqual(native_pane, {"block_id": selectable, "rect": target_rect})
            blocks = self.rex("block", "ls", "-s", session, "--json")["blocks"]
            self.assertEqual(next(block for block in blocks if block["block_id"] == target)["placement"],
                             "detached")
            for block in (target, selectable):
                size = self.rex("block", "call", "-s", session, "-b", block, "size")
                for axis in ("columns", "rows"):
                    self.assertEqual(size[axis], original_size[axis])

            subprocess.run([REX, "send", "-s", session, "-b", left, "neighbor still running"],
                           check=True, capture_output=True)
            wait_for(lambda: "neighbor still running" in frame(left))
            self.assertIn("upper-right", frame(right))
            self.assertEqual(source_window()["focused_block_id"], selectable)

            subprocess.run([REX, "send-key", "-s", session, "-b", selectable, "a"],
                           check=True, capture_output=True)
            wait_for(lambda: selectable not in [b["block_id"] for b in self.rex(
                "block", "ls", "-s", session, "--json")["blocks"]],
                lambda: self.rex("block", "call", "-s", session, "-b", selectable, "process"))
            restored = source_window()
            self.assertEqual(restored["layers"], [original_layer])
            self.assertEqual(restored["focused_block_id"], target)
            self.assertEqual(self.rex("block", "call", "-s", session, "-b", target, "process")["child"]["pid"],
                             original_pid)
            self.assertIn("192.0.2.2", frame(left))
            self.assertIn("192.0.2.1", frame(target))

            subprocess.run([REX, "send-key", "-s", session, "ctrl+d"],
                           check=True, capture_output=True)
            wait_for(lambda: {b["block_id"] for b in source_window()["layers"][0]["blocks"]}
                     == {left, right, bottom_left})
        finally:
            subprocess.run([REX, "kill", session], check=True, capture_output=True)

    def test_paginated_styles_links_and_tabs(self):
        self.check_screen(
            "\x1b[31mRED\x1b[0m\tGAP\x1b]8;;https://example.com\x1b\\"
            "LINK\x1b]8;;\x1b\\", "RED     GAPLINK", paginated=True,
        )


if __name__ == "__main__":
    unittest.main()
