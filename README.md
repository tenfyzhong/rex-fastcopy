# Rex Fastcopy

A keyboard-driven extension for highlighting, selecting, and copying text in Rex. Lua handles key bindings and screen snapshots; a Rust terminal program handles labels, selection, and copying.
Adapted from the local rmux-fastcopy project under GPL-2.0-only. See `NOTICE` and `LICENSE`.

## Usage

Press **Ctrl+S**, release it, then press **f**.

- Type a red letter label to copy its text to the macOS clipboard and exit.
- Press **Tab** to enter multiple-selection mode, then type labels. Typing the same label again deselects it. Press **Enter** or **Tab** to confirm and join the selected values with spaces.
- **Backspace** removes the last character from the label input.
- **Esc** or **Ctrl+C** cancels without changing the clipboard.
- While selecting, configured pane, session, tab, and window navigation shortcuts are intercepted, including Ctrl+h/j/k/l, prefix keys, Cmd+K, Cmd+number, and Ctrl+Tab. They are restored after selection or cancellation.
- The current Lua API cannot prevent mouse clicks on tab or session buttons. If the selection terminal loses focus, the overlay cancels and closes without stealing focus back. Start selection again after returning.
- Both the normal prefix mode and the prefix inside `terminal` passthrough mode are supported. Opening the selector exits passthrough mode so a single Esc cancels. Use Ctrl+S, t to re-enter passthrough mode when needed.

The default matchers recognize IP addresses, paths, Git hashes, UUIDs, dates, hexadecimal values, numbers, and ordinary words.
Identical text shares a label and is copied only once. Labels are assigned in text-sorted order, which also determines the order of multiple selections.

The selector preserves **original pane coordinates**: right-hand content stays on the right, left-hand content stays on the left, and labels appear only in the target pane.
Blank rows at the bottom of the screen are preserved. Content that occupies less than a full screen does not move down or pull in historical output.
During selection, each pane displays a static snapshot captured when the selector opened. Processes keep running, and the original split layout and terminal dimensions remain unchanged. Completing or cancelling selection closes the overlay and restores the source pane's focus and live display.
Snapshots use a uniform color scheme rather than the original program's colors or native pane borders. Horizontal positioning accounts for native padding, and the overlay's top offset compensates for the source pane's inset. Character positions remain subject to terminal-grid rounding.

## Files and installation

Implementation, tests, and build artifacts stay in this directory. For a manual installation, add this line to the main `~/.config/rex/init.lua`:

```lua
require("extensions.rex-fastcopy.init")
```

Place it after `require("keybindings")`. The entry point resolves modules and the executable relative to its own file, so the entire plugin directory can be relocated.

For rexpack, configure `~/.config/rex/plugins/rex-fastcopy.lua`:

```lua
return {
    "tenfyzhong/rex-fastcopy",
    build = "make build",
}
```

rexpack prefers a `rex-fastcopy` directory under `dev.path` and falls back to the installed directory when it is absent.
The plugin loads at startup and registers its actions and key bindings without explicit `dev` or `lazy` settings. It does not provide a `setup()` function.
The main configuration must call `require("keybindings")` before rexpack setup so the plugin can protect existing navigation bindings.
The module entry point is `rex-fastcopy.lua`. Build a development plugin locally with `make build`.

Build and check:

```sh
cd ~/.config/rex/extensions/rex-fastcopy
make build
make test-deps  # First test run; requires Lua 5.5 and LuaRocks
make check
```

There is no system Lua dependency at runtime: Rex uses its embedded Lua interpreter. macOS `pbcopy`, `mktemp`, and the local Rex Server CLI are required.
The default CLI path is configured by `rex_path` in `init.lua`. After changing Lua, run `rex config check` and `rex config reload`. After changing Rust, run `make build`.
If your shell cannot find `rex`, use:

```sh
"$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" config reload
```

To uninstall, remove the loading line from the main configuration and reload it, then remove this directory.

## Configuration

Edit `args` in this directory's `init.lua`. Supported options include `--alphabet`, `--regex NAME:PATTERN`, `--action`, and `--shift-action`.
The default configuration adds the same ordinary-word matcher as the original rmux configuration:

```lua
args = {"--regex", "word:\\b[^\\s]+\\b"}
```

Remove these arguments to label only the built-in structured matches, such as IP addresses and paths. The first capture group in a regex defines the copied range. An empty pattern disables a built-in matcher.
Uppercase labels use `--shift-action`; if it is unset, they still copy to the clipboard.
Action commands do not run through a shell. An argument containing `{}` is replaced with the selected text; otherwise, the text is written to the command's standard input.

### Native padding calibration

On Rex macOS 1497 at 2x display scaling, text in tiled panes starts 12 device pixels lower than in floating layers. Native horizontal padding is 16 pixels on each side. The extension compensates for both offsets to prevent a jump toward the top-left when opening. It does not insert a whole blank row as top padding.
`core.open` accepts `inset_x_px` and `inset_y_px`, defaulting to 16 and 12. Override them in the options in `init.lua`. Rex exposes integral row and column counts and character-cell pixel dimensions, but not the complete client-area pixel rectangle. Window height is estimated with a half-row allowance. Equal left/right splits have been checked on the local client; other display scales, arbitrary split ratios, and top/bottom splits have not received pixel-level alignment verification.

## Current limitations

- Verified with Rex Beta **0.1.0 (1497)**. Offset floating layers showed clipping and background-display problems in this version, so the extension uses a window-sized drawing surface and redraws each pane at its original coordinates. It does not enlarge the target pane or move its content to the top-left.
- Snapshots capture the terminal's **bottom screen**, not the historical viewport shown after scrolling up in the client. Return to the bottom before opening the selector.
- Every pane in the window must currently be a readable terminal. If any snapshot fails, the selector does not open.
- Long history is read in pages through `blob_read`, retaining only text near the final screen. Each pane is limited to 128 MiB and 256 continuation pages. Failures do not display partial snapshots.
- `mktemp` creates private snapshot files. The interactive program deletes them immediately after reading; failed overlay creation also removes them. If the process is forcibly terminated before reading, snapshots may remain in the system temporary directory.
- The extension currently targets local macOS sessions. File paths and clipboard routing with a remote Rex Server have not been verified.
- Wrapped paths are matched by physical screen line; paths are not joined across lines.

## Verification

`tests/core.rs` covers matching, shared labels, single and multiple selection, and action arguments. Rust rendering tests cover labels on short tokens and wide Chinese characters.
`tests/test_core.lua` covers partially filled and empty screens, VT styles, erase-character sequences, blank-column decoding, pagination, independent overlays, failure cleanup, and focus-return arguments.
`tests/test_guard.lua` covers isolation by client, startup protection, overlay closure, and automatic release after failures. Lua entry-point tests cover shortcut interception and restoration.
`tests/test_terminal.py` drives the executable through a real PTY. It covers single and multiple selection, cancellation, empty screens, private snapshot deletion, right-pane positioning, neighboring-pane visibility, focus restoration, and cancellation on focus loss without stealing focus back.

`tests/demo.py` provides a reusable manual verification screen. Run it in a new Rex tab, then use the shortcut to select IP addresses, paths, and Chinese text. Press `q` to exit the demo.

Navigation protection has been checked on the local client: Ctrl+h/l, Ctrl+S, Cmd+K, Cmd+1, and Ctrl+Tab do not navigate away while selecting in the right pane. Typing ac copies 192.0.2.10, and Ctrl+h/l work again after exit. Switching tabs with the mouse closes the overlay automatically; selection can be restarted and cancelled after returning. The regular test suite contains 44 passing tests.

Optional live Rex tests create and clean up isolated sessions. They cover partially filled and empty screens, pagination, colors, links, and tab spacing, and verify that the source terminal remains unchanged. They also open a real selector overlay and complete selection by typing a label; the test action does not write to the clipboard:

```sh
REX_FASTCOPY_TEST_REX="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" make test-rex
```
