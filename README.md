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
- The current Lua API cannot prevent mouse clicks on tab or session buttons. If the selection terminal loses focus, the picker cancels and closes without stealing focus back. Start selection again after returning.
- Both the normal prefix mode and the prefix inside `terminal` passthrough mode are supported. Opening the selector exits passthrough mode so a single Esc cancels. Use Ctrl+S, t to re-enter passthrough mode when needed.

The default matchers recognize IP addresses, paths, Git hashes, UUIDs, dates, hexadecimal values, numbers, and ordinary words.
Identical text shares a label and is copied only once. Labels are assigned in text-sorted order, which also determines the order of multiple selections.

The selector preserves **original pane coordinates**: right-hand content stays on the right, left-hand content stays on the left, and labels appear only in the target pane.
Blank rows at the bottom of the screen are preserved. Content that occupies less than a full screen does not move down or pull in historical output.
For a tiled layout, Fastcopy displays static snapshots in a temporary tab with the same native splits. Rex gives both tabs the same pane padding and terminal grid. The original terminals keep running at their existing dimensions. Selecting a value or cancelling closes the picker tab and returns to the source pane.
Snapshots use a uniform color scheme. If a picker pane becomes narrower during selection, it clips excess columns so subsequent rows retain their positions.

## Files and installation

Implementation, tests, and build artifacts stay in this directory. For a manual installation, add this line to the main `~/.config/rex/init.lua`:

```lua
local directory = os.getenv("HOME") .. "/.config/rex/extensions/rex-fastcopy"
package.path = directory .. "/lua/?.lua;" .. directory .. "/lua/?/init.lua;" .. package.path
require("rex-fastcopy")
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
The module entry point is `lua/rex-fastcopy/init.lua`; `core.lua` and `guard.lua` live alongside it. rexpack adds the `lua/` search paths automatically. Build a development plugin locally with `make build`.

Build and check:

```sh
cd ~/.config/rex/extensions/rex-fastcopy
make build
make test-deps  # First test run; requires Lua 5.5 and LuaRocks
make check
```

There is no system Lua dependency at runtime: Rex uses its embedded Lua interpreter. macOS `pbcopy`, `mktemp`, and the local Rex Server CLI are required.
The default CLI path is configured by `rex_path` in `lua/rex-fastcopy/init.lua`. After changing Lua, run `rex config check` and `rex config reload`. After changing Rust, run `make build`.
If your shell cannot find `rex`, use:

```sh
"$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" config reload
```

To uninstall, remove the loading line from the main configuration and reload it, then remove this directory.

## Configuration

Edit `args` in `lua/rex-fastcopy/init.lua`. Supported options include `--alphabet`, `--regex NAME:PATTERN`, `--action`, and `--shift-action`.
The default configuration adds an ordinary-word matcher that keeps leading dots attached when copying names like `.alias.bash` and paths like `./file`.

```lua
args = {"--regex", "word:(?:\\.|\\b)\\S+\\b"}
```

Remove these arguments to label only the built-in structured matches, such as IP addresses and paths. The first capture group in a regex defines the copied range. An empty pattern disables a built-in matcher.
Alphabet characters are normalized to lowercase; duplicates after normalization (such as `aA`) are rejected. Uppercase label input uses `--shift-action`; if it is unset, it still copies to the clipboard. Backspace removes the deleted character's shift state. In multiple-selection mode, only retained selections contribute to the shift action.
Action commands do not run through a shell. An argument containing `{}` is replaced with the selected text; otherwise, the text is written to the command's standard input.

## Current limitations

- Verified with Rex **0.1.0 (2061)** on macOS. Rex may open the temporary picker tab in its main window when the source tab is detached.
- Layouts with visible floating panes use a window-sized floating overlay. Rex applies floating-window insets to its grid. Use `inset_x_px` and `inset_y_px` in the options passed to `core.open` to tune that overlay.
- Snapshots capture the terminal's **bottom screen**, not the historical viewport shown after scrolling up in the client. Return to the bottom before opening the selector.
- Every pane in the window must currently be a readable terminal. If any snapshot fails, the selector does not open.
- Long history is read in pages through `blob_read`, retaining only text near the final screen. Each pane is limited to 128 MiB and 256 continuation pages. Failures do not display partial snapshots.
- `mktemp` creates private snapshot files. The interactive program deletes them immediately after reading; failed overlay creation also removes them. If the process is forcibly terminated before reading, snapshots may remain in the system temporary directory.
- The extension currently targets local macOS sessions. File paths and clipboard routing with a remote Rex Server have not been verified.
- Wrapped paths are matched by physical screen line; paths are not joined across lines.

## Verification

The GitHub Actions `Tests` workflow runs on pull requests and pushes to `main`, and also supports manual dispatch. Linux and macOS runners install Rust stable, Lua 5.5.1, LuaRocks, and Python, then run `make test-deps`, `make check`, and `make build`. This covers formatting, Clippy, Rust and Lua tests, PTY tests, and the release build. Live Rex integration tests remain opt-in locally because hosted runners do not provide a configured Rex server.

`tests/core.rs` covers matching, shared labels, single and multiple selection, and action arguments. Rust rendering tests cover labels on short tokens and wide Chinese characters.
`tests/test_core.lua` covers partially filled and empty screens, VT styles, erase-character sequences, blank-column decoding, pagination, cloned tiled layouts, independent overlays, failure cleanup, and focus-return arguments.
`tests/test_guard.lua` covers isolation by client, startup protection, overlay closure, and automatic release after failures. Lua entry-point tests cover shortcut interception and restoration.
`tests/test_terminal.py` drives the executable through a real PTY. It covers single and multiple selection, cancellation, empty screens, private snapshot deletion, right-pane positioning, neighboring-pane visibility, focus restoration, and cancellation on focus loss without stealing focus back.

`tests/demo.py` provides a reusable manual verification screen. Run it in a new Rex tab, then use the shortcut to select IP addresses, paths, and Chinese text. Press `q` to exit the demo.

The tiled picker has been checked in Rex with a left pane and two vertically stacked right panes. Labels appeared in the bottom-right pane and cancellation restored the original tab.

Optional live Rex tests create and clean up isolated sessions. They cover partially filled and empty screens, pagination, colors, links, and tab spacing. They also verify that the picker tab inherits the source grid and closes after label selection. The test action uses `/usr/bin/true` to leave the clipboard intact.

```sh
REX_FASTCOPY_TEST_REX="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" make test-rex
```
