package.path = "./lua/?.lua;./lua/?/init.lua;./.test-deps/share/lua/5.5/?.lua;" .. package.path
local lu = require("luaunit")
local fastcopy = require("rex-fastcopy.core")

TestFastcopy = {}
function TestFastcopy:testScreenTailPreservesBlankRows()
    lu.assertEquals(fastcopy.screen_tail("history\nfirst\n\nlast", 3), "first\n\nlast")
    lu.assertEquals(fastcopy.screen_tail("first\n\n", 3), "first\n\n")
    lu.assertEquals(fastcopy.screen_tail("中文\nlast", 1), "last")
end

function TestFastcopy:setUp()
    self.path = os.tmpname()
    self.created = {}
    self.view = { windows = {{ window_id = "w", layers = {{
        layer_id = "source-layer",
        bounds = {0.1, 0.2, 0.8, 0.6},
        layout = { split = { direction = "horizontal", ratio = 0.5,
            before = { block_id = "left", rect = {0.1, 0.2, 0.4, 0.6} },
            after = { block_id = "target", rect = {0.5, 0.2, 0.4, 0.6} },
        }},
    }}}}}
    self.api = {
        json = {encode = function(args)
            self.watcher_args = args
            return "{}"
        end},
        exec = setmetatable({start = function(argv, options)
            self.watcher = argv
            lu.assertTrue(options.detach)
            return {}
        end}, {__call = function(_, argv)
            lu.assertEquals(argv[1], "/usr/bin/mktemp")
            return { ok = true, stdout = self.path .. "\n" }
        end}),
        session = {
            view = function() return self.view end,
            new_layer = function(args)
                self.created = args
                return {layer_id = "overlay", block_ids = {"overlay-block"}}
            end,
            set_layer_state = function(args)
                self.layer_state = args
                return {}
            end,
        },
        block = { call = function(_, method, args)
            lu.assertEquals(args.block_id, "target")
            if method == "size" then return {columns = 40, rows = 3} end
            if method == "format" then return {content = "history\none\ntwo\nthree"} end
            error("unexpected method " .. method)
        end },
    }
end
function TestFastcopy:tearDown()
    os.remove(self.path)
    os.remove(self.path .. ".ready")
end

function TestFastcopy:testOpensOnlyTargetPaneWithoutLayoutMutation()
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    lu.assertEquals(self.created.bounds, {0.5, 0.2, 0.4, 0.6})
    lu.assertEquals(self.created.window_id, "w")
    lu.assertTrue(self.created.focus)
    local options = self.created.layout.block.options
    lu.assertEquals(options.shell, "none")
    lu.assertEquals(options.size, {columns = 40, rows = 3})
    lu.assertTrue(options.exit.on_completion)
    lu.assertEquals(options.command, {"/extension/target/release/rex-fastcopy",
        "--snapshot", self.path, "--pane", "target"})
    local file = assert(io.open(self.path))
    lu.assertEquals(file:read("*a"), "one\ntwo\nthree")
    file:close()
end

function TestFastcopy:testHalfScreenDoesNotPullHistoryIntoView()
    self.api.block.call = function(_, method, args)
        if method == "size" then return {columns = 40, rows = 6} end
        lu.assertEquals(args.format, "vt")
        lu.assertFalse(args.unwrap)
        return {content = "old history\r\n192.0.2.1\r\nsecond line" .. string.rep("\r\n", 4)}
    end
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    local file = assert(io.open(self.path))
    lu.assertEquals(file:read("*a"), "192.0.2.1\nsecond line" .. string.rep("\n", 4))
    file:close()
end

function TestFastcopy:testBlankScreenDoesNotShowHistory()
    self.api.block.call = function(_, method)
        if method == "size" then return {columns = 40, rows = 3} end
        return {content = "old history\r\n\r\n\r\n"}
    end
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    local file = assert(io.open(self.path))
    lu.assertEquals(file:read("*a"), "\n\n")
    file:close()
end

function TestFastcopy:testPaginatedVtPreservesBlanksAndRemovesStyles()
    self.api.block.call = function(_, method, args)
        if method == "size" then return {columns = 40, rows = 4} end
        if method == "format" then return {content = "history\r\n\27[3", id = 12} end
        lu.assertEquals(args.offset, #"history\r\n\27[3")
        return {data = "1m中文\27[0m 192.0.2.1\r\n\r\n\r\n", eof = true}
    end
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    local file = assert(io.open(self.path))
    lu.assertEquals(file:read("*a"), "中文 192.0.2.1\n\n\n")
    file:close()
end

function TestFastcopy:testVtStylesLinksAndBlankColumnsKeepTextPositions()
    self.api.block.call = function(_, method)
        if method == "size" then return {columns = 40, rows = 3} end
        return {content = "\27[31mRED\27[5C\27[0mGAP\27]8;;https://example.com\27\\LINK\27]8;;\27\\\r\n\r\n"}
    end
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    local file = assert(io.open(self.path))
    lu.assertEquals(file:read("*a"), "RED     GAPLINK\n\n")
    file:close()
end

function TestFastcopy:testVtEraseCellsDoesNotMoveCursor()
    self.api.block.call = function(_, method)
        if method == "size" then return {columns = 40, rows = 3} end
        return {content = "\27[41m\27[40X\27[0m192.0.2.1\27[5X\27[5CGAP\r\n\27[X\r\n"}
    end
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    local file = assert(io.open(self.path))
    lu.assertEquals(file:read("*a"), "192.0.2.1     GAP\n\n")
    file:close()
end

function TestFastcopy:testTiledPickerPreparesAMinimizedLayerForTheSwap()
    local layer = self.view.windows[1].layers[1]
    layer.kind = "tiled"
    layer.bounds = {0, 0, 1, 1}
    layer.layout.split.before.rect = {0, 0, 0.5, 1}
    layer.layout.split.after.rect = {0.5, 0, 0.5, 1}
    local result = fastcopy.open(self.api, {session_id = "s", block_id = "target"},
        {directory = "/extension", rex_path = "/bin/rex"})

    lu.assertEquals(result.block_ids, {"overlay-block"})
    lu.assertEquals(self.created.session_id, "s")
    lu.assertEquals(self.created.window_id, "w")
    lu.assertEquals(self.created.bounds, {0.5, 0, 0.5, 1})
    lu.assertFalse(self.created.focus)
    lu.assertEquals(self.layer_state, {session_id = "s", layer_id = "overlay", state = "minimized"})
    local options = self.created.layout.block.options
    lu.assertFalse(options.exit.on_completion)
    lu.assertStrContains(table.concat(options.command, " "), "--keep-frame-on-exit")
    lu.assertStrContains(table.concat(options.command, " "), "--wait-for-snapshot")
    lu.assertEquals(options.size, {columns = 40, rows = 3})
    lu.assertEquals(self.watcher_args, {
        core = "/extension/lua/rex-fastcopy/core.lua", session = "s", source = "target",
        picker = "overlay-block", layer = "overlay", source_layer = "source-layer", rex_path = "/bin/rex",
        native = true, zoomed = false,
        snapshot = self.path, ready = self.path .. ".ready",
    })
end

function TestFastcopy:testZoomedPickerPreservesSourceGridAndPassesZoomState()
    local window = self.view.windows[1]
    window.layers[1].kind = "tiled"
    window.zoomed_block_id = "target"
    fastcopy.open(self.api, {session_id = "s", block_id = "target"},
        {directory = "/extension", rex_path = "/bin/rex"})
    lu.assertEquals(self.created.bounds, {0, 0, 1, 1})
    lu.assertFalse(self.created.focus)
    lu.assertEquals(self.created.layout.block.options.size, {columns = 40, rows = 3})
    lu.assertTrue(self.watcher_args.zoomed)
end

function TestFastcopy:testFailedLayerRemovesSnapshot()
    self.api.session.new_layer = function() return nil, "failed layer" end
    lu.assertErrorMsgContains("failed layer", fastcopy.open, self.api,
        {session_id = "s", block_id = "target"}, {directory = "/extension"})
    lu.assertNil(io.open(self.path))
end

function TestFastcopy:testFailedWatcherClosesOnlyPickerAndRemovesSnapshot()
    local closed
    self.api.exec.start = function() return nil, "failed watcher" end
    self.api.call = function(method, args)
        lu.assertEquals(method, "block.close")
        closed = args
    end
    lu.assertErrorMsgContains("failed watcher", fastcopy.open, self.api,
        {session_id = "s", block_id = "target"}, {directory = "/extension", rex_path = "/bin/rex"})
    lu.assertEquals(closed, {session_id = "s", block_id = "overlay-block"})
    lu.assertNil(io.open(self.path))
    lu.assertNil(io.open(self.path .. ".ready"))
end

function TestFastcopy:testRestorationSwapsBackBeforeRestoringZoomAndReleasingTheGrid()
    for _, focused in ipairs({"picker", "neighbor"}) do
        local calls = {}
        local function record(name)
            calls[#calls + 1] = name
        end
        local function view(block, zoomed, swapped)
            return {active_window_id = "w", windows = {{
                window_id = "w", focused_block_id = block, zoomed_block_id = zoomed, layers = {
                    {layer_id = "native", layout = {block_id = swapped and "picker" or "source",
                        rect = {0, 0, 1, 1}}},
                    {layer_id = "overlay", layout = {block_id = swapped and "source" or "picker",
                        rect = {0, 0, 1, 1}}},
                },
            }}}
        end
        local narrow_request = true
        local api = {
            call = function(method, args)
                if method == "block.close" then
                    lu.assertEquals(args, {session_id = "s", block_id = "picker"})
                else
                    lu.assertEquals(args.block_ids, {"source"})
                end
                record(method)
                return {blocks = {{owner = "watcher"}}}
            end,
            block = {call = function(_, method, args)
                lu.assertEquals(method, "size")
                lu.assertEquals(args.block_id, "source")
                return {columns = 80, rows = 24, owner = "app", desired = {
                    {client_id = "app", columns = narrow_request and 40 or 80, rows = 24},
                }}
            end},
            session = {
                attach = function()
                    return {client_id = "watcher", view = view("source", "source")}
                end,
                view = function() return view(focused, "picker", true) end,
                swap_blocks = function(args)
                    lu.assertEquals(args, {session_id = "s", block_id = "source", other_block_id = "picker"})
                    record("swap")
                    return {}
                end,
                set_layer_state = function(args)
                    lu.assertEquals(args, {session_id = "s", layer_id = "overlay", state = "minimized"})
                    record("minimize")
                    return {}
                end,
                zoom_block = function(args)
                    lu.assertTrue(args.zoom)
                    record("zoom " .. args.block_id)
                    return {}
                end,
            },
            exec = function() record("wait for picker") end,
            sleep = function()
                record("wait for full grid")
                narrow_request = false
            end,
        }
        assert(io.open(self.path, "w")):close()
        fastcopy.wait_for_picker(api, {session = "s", source = "source", picker = "picker",
            layer = "overlay", source_layer = "native", rex_path = "/bin/rex", snapshot = self.path,
            ready = self.path .. ".ready", native = true, zoomed = true,
        })
        local expected = {"session.own_block", "swap", "zoom picker", "minimize", "wait for picker", "swap"}
        if focused == "picker" then
            expected[#expected + 1] = "zoom source"
            expected[#expected + 1] = "wait for full grid"
        end
        expected[#expected + 1] = "session.disown_block"
        expected[#expected + 1] = "block.close"
        lu.assertEquals(calls, expected)
        lu.assertNil(io.open(self.path))
        lu.assertNil(io.open(self.path .. ".ready"))
    end
end

function TestFastcopy:testPaginatedCaptureKeepsFinalRows()
    self.api.block.call = function(_, method, args)
        if method == "size" then return {columns = 40, rows = 3} end
        if method == "format" then return {content = "history\n中", id = 12} end
        lu.assertEquals(method, "blob_read")
        lu.assertEquals(args.offset, #"history\n中")
        lu.assertEquals(args.id, 12)
        return {data = "文\none\ntwo\nthree", eof = true}
    end
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    local file = assert(io.open(self.path))
    lu.assertEquals(file:read("*a"), "one\ntwo\nthree")
    file:close()
end

function TestFastcopy:testLargeCaptureFailsWithoutOpeningPartialOverlay()
    self.api.block.call = function(_, method)
        if method == "size" then return {columns = 40, rows = 3} end
        return {content = "partial", id = 12}
    end
    lu.assertErrorMsgContains("capture", fastcopy.open, self.api,
        {session_id = "s", block_id = "target"}, {directory = "/extension"})
    lu.assertEquals(self.created, {})
end

function TestFastcopy:testMissingPaneDoesNotCreateLayer()
    lu.assertErrorMsgContains("pane", fastcopy.open, self.api,
        {session_id = "s", block_id = "missing"}, {directory = "/extension"})
    lu.assertEquals(self.created, {})
end

function TestFastcopy:testEntryGuardsNavigationAndReleasesAfterClose()
    local saved_rex = _G.rex
    local saved_core = package.loaded["rex-fastcopy.core"]
    local actions, queued, bound, writes, blocks = {}, {}, {}, {}, {{block_id = "picker"}}
    local opens, directory = 0, nil
    package.loaded["rex-fastcopy.core"] = {open = function(_, _, options)
        opens = opens + 1
        directory = options.directory
        return {layer_id = "test", block_ids = {"picker"}}
    end}
    _G.rex = {
        action = function(value) actions[value.name] = value end,
        bindings = function() return {
            {key = "ctrl+h", action = "pane.focus", args = {direction = "left"}},
            {key = "ctrl+s", action = "client.mode.enter", args = {name = "prefix"}},
            {mode = "terminal", key = "esc", action = "pane.send_key", args = {key = "escape"}},
        } end,
        bind = function(key, action, args) bound[key] = {action = action, args = args} end,
        session = {list_blocks = function() return {blocks = blocks} end},
        block = {call = function(creator, method, args)
            lu.assertEquals({creator, method}, {"com.superlogical.terminal", "write"})
            writes[#writes + 1] = args
            return {bytes_written = 1}
        end},
        client = {queue = function(name) queued[#queued + 1] = name end},
    }
    dofile(os.getenv("PWD") .. "/lua/rex-fastcopy/init.lua")
    local ctx = {session_id = "s", block_id = "target", client_id = "client"}
    local result = actions.fastcopy.run(ctx)
    lu.assertEquals(result.layer_id, "test")
    lu.assertEquals(directory, os.getenv("PWD"))
    lu.assertEquals(queued, {"client.mode.exit_all"})
    for _, key in ipairs({"ctrl+h", "ctrl+s", "cmd+k", "cmd+1"}) do
        local binding = bound[key]
        lu.assertEquals(binding.action, "fastcopy_guard")
        actions[binding.action].run(ctx, binding.args)
    end
    lu.assertEquals(queued, {"client.mode.exit_all"})
    local escape = bound.escape.action
    local picker = {session_id = "s", block_id = "picker", client_id = "client"}
    lu.assertFalse(escape(ctx))
    lu.assertFalse(escape({session_id = "s", block_id = "picker", client_id = "another"}))
    lu.assertFalse(escape({session_id = "other", block_id = "picker", client_id = "client"}))
    lu.assertEquals(writes, {})
    lu.assertTrue(escape(picker))
    local passthrough = bound["terminal/esc"]
    lu.assertEquals(passthrough.args, {action = "pane.send_key", original_args = {key = "escape"}})
    actions[passthrough.action].run(picker, passthrough.args)
    local cancel = {session_id = "s", block_id = "picker", data = "\3"}
    lu.assertEquals(writes, {cancel, cancel})
    actions.fastcopy.run(ctx)
    lu.assertEquals(opens, 1, "must not open another picker while selecting")
    blocks = {}
    actions.fastcopy_guard.run(ctx, bound["ctrl+h"].args)
    lu.assertFalse(escape(ctx))
    actions[passthrough.action].run(ctx, passthrough.args)
    lu.assertEquals(queued, {"client.mode.exit_all", "pane.focus", "pane.send_key"})
    _G.rex = saved_rex
    package.loaded["rex-fastcopy.core"] = saved_core
end

function TestFastcopy:testRexpackModuleRegistersBindingsWithoutLegacyPaths()
    local saved_rex = _G.rex
    local actions, bindings = {}, {}
    _G.rex = {
        action = function(action) actions[action.name] = action end,
        bind = function(key, action) bindings[key] = action end,
        bindings = function() return {} end,
    }
    package.loaded["rex-fastcopy"] = nil
    local ok, err = pcall(require, "rex-fastcopy")
    _G.rex = saved_rex
    package.loaded["rex-fastcopy"] = nil
    lu.assertTrue(ok, tostring(err))
    lu.assertNotNil(actions.fastcopy)
    lu.assertEquals(bindings["prefix/f"], "fastcopy")
    lu.assertEquals(bindings["terminal_prefix/f"], "fastcopy")
end

function TestFastcopy:testConfiguredEscapeRunsOriginalActionOutsidePicker()
    local saved_rex = _G.rex
    local saved_core = package.loaded["rex-fastcopy.core"]
    for _, original in ipairs({
        {action = "pane.focus", args = {direction = "left"}, route = "client"},
        {action = "custom_escape", args = {target = "editor"}, route = "server"},
    }) do
        local actions, bindings, forwarded, writes = {}, {}, {}, {}
        local write_error
        local function forward(route, action, args)
            if action ~= "client.mode.exit_all" then
                forwarded[#forwarded + 1] = {route, action, args}
            end
        end
        package.loaded["rex-fastcopy.core"] = {open = function() return {block_ids = {"picker"}} end}
        _G.rex = {
            action = function(action) actions[action.name] = action end,
            bind = function(key, action, args) bindings[key] = {action = action, args = args} end,
            bindings = function() return {
                {key = "escape", action = "pane.send_key", args = {key = "escape"}},
                {key = "esc", action = original.action, args = original.args},
            } end,
            session = {list_blocks = function() return {blocks = {}} end},
            block = {call = function(_, _, args)
                if write_error then return nil, write_error end
                writes[#writes + 1] = args
                return {bytes_written = 1}
            end},
            client = {queue = function(name, args) forward("client", name, args) end},
            invoke = function(name, args) forward("server", name, args) end,
        }
        dofile(os.getenv("PWD") .. "/lua/rex-fastcopy/init.lua")
        local binding = bindings.escape
        lu.assertIsString(binding.action)
        local run_escape = actions[binding.action].run
        local source = {session_id = "s", block_id = "source", client_id = "client"}
        local picker = {session_id = "s", block_id = "picker", client_id = "client"}
        run_escape(source, binding.args)
        actions.fastcopy.run(source)
        run_escape(picker, binding.args)
        run_escape(source, binding.args)
        lu.assertEquals(forwarded, {
            {original.route, original.action, original.args},
            {original.route, original.action, original.args},
        })
        lu.assertEquals(writes, {{session_id = "s", block_id = "picker", data = "\3"}})
        write_error = "picker input is unavailable"
        lu.assertErrorMsgContains(write_error, run_escape, picker, binding.args)
        lu.assertEquals(#forwarded, 2)
        _G.rex = saved_rex
        package.loaded["rex-fastcopy.core"] = saved_core
    end
end

os.exit(lu.LuaUnit.run())
