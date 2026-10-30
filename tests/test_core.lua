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
    self.background_path = os.tmpname()
    self.created = {}
    self.temp_created = false
    self.view = { windows = {{ window_id = "w", layers = {{
        bounds = {0.1, 0.2, 0.8, 0.6},
        layout = { split = { direction = "horizontal", ratio = 0.5,
            before = { block_id = "left", rect = {0.1, 0.2, 0.4, 0.6} },
            after = { block_id = "target", rect = {0.5, 0.2, 0.4, 0.6} },
        }},
    }}}}}
    self.api = {
        exec = function(argv)
            lu.assertEquals(argv[1], "/usr/bin/mktemp")
            local path = self.temp_created and self.background_path or self.path
            self.temp_created = true
            return { ok = true, stdout = path .. "\n" }
        end,
        session = {
            view = function() return self.view end,
            new_layer = function(args)
                self.created = args
                return {layer_id = "overlay", block_ids = {"overlay-block"}}
            end,
        },
        block = { call = function(_, method, args)
            if args.block_id == "left" then
                if method == "size" then return {columns = 40, rows = 3} end
                return {content = "neighbor stays here\n\n\n"}
            end
            lu.assertEquals(args.block_id, "target")
            if method == "size" then return {columns = 40, rows = 3} end
            if method == "format" then return {content = "history\none\ntwo\nthree"} end
            error("unexpected method " .. method)
        end },
    }
end
function TestFastcopy:tearDown()
    os.remove(self.path)
    os.remove(self.background_path)
end

function TestFastcopy:testOpensOnlyTargetPaneWithoutLayoutMutation()
    fastcopy.open(self.api, {session_id = "s", block_id = "target"}, {directory = "/extension"})
    lu.assertEquals(self.created.bounds, {0, 0, 1, 1})
    lu.assertStrContains(table.concat(self.created.layout.block.options.command, " "),
        "--region 0.5,0.2,0.4,0.6")
    lu.assertStrContains(table.concat(self.created.layout.block.options.command, " "),
        "--background 0.1,0.2,0.4,0.6:" .. self.background_path)
    lu.assertEquals(self.created.window_id, "w")
    lu.assertTrue(self.created.focus)
    local options = self.created.layout.block.options
    lu.assertEquals(options.shell, "none")
    lu.assertEquals(options.size, {columns = 100, rows = 5})
    lu.assertEquals(options.command[1], "/extension/target/release/rex-fastcopy")
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

function TestFastcopy:testLayerAccountsForNativeTopInset()
    local rect = fastcopy.overlay_bounds({rows = 58, cell_height_px = 35}, {0.5, 0, 0.5, 1})
    -- Native tiled panes inset their text by 12 device pixels at 2x scaling.
    lu.assertAlmostEquals(rect[2] * 2080, 12, 0.25)
    lu.assertEquals(rect[1], 0)
    lu.assertAlmostEquals(rect[2] + rect[4], 1, 0.000001)
end

function TestFastcopy:testFailedLayerRemovesSnapshot()
    self.api.session.new_layer = function() return nil, "failed layer" end
    lu.assertErrorMsgContains("failed layer", fastcopy.open, self.api,
        {session_id = "s", block_id = "target"}, {directory = "/extension"})
    lu.assertNil(io.open(self.path))
end

function TestFastcopy:testPassesFocusReturnTarget()
    fastcopy.open(self.api, {session_id = "s", block_id = "target"},
        {directory = "/extension", rex_path = "/bin/rex"})
    local command = table.concat(self.created.layout.block.options.command, " ")
    lu.assertStrContains(command, "--rex /bin/rex --session s")
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
    local actions, queued, bound, layers = {}, {}, {}, {{layer_id = "test"}}
    local opens, directory = 0, nil
    package.loaded["rex-fastcopy.core"] = {open = function(_, _, options)
        opens = opens + 1
        directory = options.directory
        return {layer_id = "test"}
    end}
    _G.rex = {
        action = function(value) actions[value.name] = value end,
        bindings = function() return {
            {key = "ctrl+h", action = "pane.focus", args = {direction = "left"}},
            {key = "ctrl+s", action = "client.mode.enter", args = {name = "prefix"}},
        } end,
        bind = function(key, action, args) bound[key] = {action = action, args = args} end,
        session = {view = function() return {windows = {{layers = layers}}} end},
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
    actions.fastcopy.run(ctx)
    lu.assertEquals(opens, 1, "must not open another picker while selecting")
    layers = {}
    actions.fastcopy_guard.run(ctx, bound["ctrl+h"].args)
    lu.assertEquals(queued, {"client.mode.exit_all", "pane.focus"})
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

os.exit(lu.LuaUnit.run())
