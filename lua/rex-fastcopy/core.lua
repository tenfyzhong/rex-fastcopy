local M = {}
local terminal = "com.superlogical.terminal"

function M.screen_tail(text, rows)
    text = text:gsub("\r\n", "\n")
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    return table.concat(lines, "\n", math.max(1, #lines - rows + 1))
end

-- Rex's VT export preserves unused bottom rows; text export omits them.
-- Decode only the decoration and blank-cell commands emitted by that export.
-- Optional terminal-state extras are deliberately not requested.
local function screen_text(text, rows, columns)
    text = text:gsub("\27%].-\27\\", ""):gsub("\27%].-\7", "")
    text = text:gsub("\27%[[0-9;:]*m", "")
    -- ECH paints blank cells without moving the cursor. The snapshot starts
    -- blank and discards styling, so only a subsequent CUF contributes spaces.
    text = text:gsub("\27%[%d*X", "")
    text = text:gsub("\27%[(%d*)C", function(count)
        local width = tonumber(count) or 1
        return string.rep(" ", math.min(math.max(width, 1), columns))
    end)
    assert(not text:find("\27", 1, true), "fastcopy: unsupported VT snapshot sequence")
    return M.screen_tail(text, rows)
end

local function find_node(node, block_id)
    if node.block_id == block_id then return node.rect end
    if node.split then
        return find_node(node.split.before, block_id) or find_node(node.split.after, block_id)
    end
end

local function locate(view, block_id)
    for _, window in ipairs(view.windows or {}) do
        for _, layer in ipairs(window.layers or {}) do
            local rect = layer.layout and find_node(layer.layout, block_id)
            if rect then
                -- Rex view rectangles are already relative to the whole window.
                return window, layer, rect
            end
        end
    end
end

local function capture_screen(api, session_id, block_id)
    local target = {session_id = session_id, block_id = block_id}
    local dimensions, size_err = api.block.call(terminal, "size", target)
    assert(dimensions, size_err)
    local capture, capture_err = api.block.call(terminal, "format", {
        session_id = session_id, block_id = block_id,
        format = "vt", trim = false, unwrap = false, max_bytes = 983040,
    })
    assert(capture, "fastcopy: capture failed: " .. tostring(capture_err))
    local content, offset = capture.content, #capture.content
    if capture.id then
        for page = 1, 256 do
            local part, part_err = api.block.call(terminal, "blob_read", {
                session_id = session_id, block_id = block_id,
                id = capture.id, offset = offset, max_bytes = 983040,
            })
            assert(part and part.data and #part.data > 0,
                "fastcopy: capture continuation failed: " .. tostring(part_err))
            offset = offset + #part.data
            assert(offset <= 128 * 1024 * 1024, "fastcopy: capture exceeds 128 MiB")
            -- Keep only the final screen plus the incomplete line between chunks.
            local combined = content .. part.data
            content = M.screen_tail(combined, dimensions.rows + 1)
            if part.eof then break end
            assert(page < 256, "fastcopy: capture exceeded page limit")
        end
    end
    return screen_text(content, dimensions.rows, dimensions.columns), dimensions
end

local run_picker = [[
return dofile(rex.args.core).wait_for_picker(rex, rex.args)
]]

function M.wait_for_picker(api, args)
    local session_id, source, picker = args.session, args.source, args.picker
    local target = {session_id = session_id, block_id = source}
    local source_block = {session_id = session_id, block_ids = {source}}
    local swap = {session_id = session_id, block_id = source, other_block_id = picker}
    local parking = {session_id = session_id, layer_id = args.layer, state = "minimized"}
    local original_size, claimed, source_parked
    local function focus(block)
        if args.zoomed then
            return api.session.zoom_block{session_id = session_id, block_id = block, zoom = true}
        end
        return api.session.focus_block{session_id = session_id, block_id = block}
    end
    local ok, err = pcall(function()
        if args.native then
            local attached = assert(api.session.attach{session_id = session_id})
            local window, layer = locate(attached.view, source)
            local picker_window, picker_layer = locate(attached.view, picker)
            assert(window and window == picker_window and layer.layer_id == args.source_layer
                and picker_layer.layer_id == args.layer
                and attached.view.active_window_id == window.window_id
                and window.focused_block_id == source
                and (window.zoomed_block_id == source) == args.zoomed, "fastcopy: source pane changed")
            original_size = assert(api.block.call(terminal, "size", target))
            if original_size.owner then
                -- The app can request a different terminal size while the
                -- source is in the parking layer. Keep its original grid.
                local owned = assert(api.call("session.own_block", {
                    session_id = session_id, block_ids = {source}, mode = "take",
                }))
                assert(owned.blocks[1].owner == attached.client_id, "fastcopy: could not preserve the source grid")
                claimed = true
            end
            assert(api.session.swap_blocks(swap))
            source_parked = true
            assert(focus(picker))
            assert(api.session.set_layer_state(parking))
        end
        assert(os.rename(args.snapshot, args.ready))
        api.exec({args.rex_path, "--autostart=false", "wait", "-s", session_id, picker})
    end)
    os.remove(args.snapshot)
    os.remove(args.ready)

    local restored, restore_err = pcall(function()
        if source_parked then
            local view = assert(api.session.view{session_id = session_id})
            local window, layer = locate(view, source)
            local picker_window, picker_layer = locate(view, picker)
            assert(window and window == picker_window and layer.layer_id == args.layer
                and picker_layer.layer_id == args.source_layer, "fastcopy: picker pane was moved or closed")
            local restore_focus = view.active_window_id == window.window_id and
                (window.focused_block_id == picker or window.focused_block_id == source)
            assert(api.session.swap_blocks(swap))
            source_parked = false
            if restore_focus then assert(focus(source)) end
            if claimed and view.active_window_id == window.window_id and (restore_focus or not args.zoomed) then
                -- A size requested for the floating grid would take effect
                -- as soon as ownership returns. Wait for the native size.
                for _ = 1, 20 do
                    local size = assert(api.block.call(terminal, "size", target))
                    local pending_resize = false
                    for _, request in ipairs(size.desired or {}) do
                        if request.client_id == original_size.owner then
                            pending_resize = request.columns ~= original_size.columns
                                or request.rows ~= original_size.rows
                            break
                        end
                    end
                    if not pending_resize then break end
                    api.sleep(0.025)
                end
            end
        end
    end)
    if claimed then api.call("session.disown_block", source_block) end
    if source_parked then
        -- A removed picker has no native slot to swap back into. Keep the
        -- live terminal accessible without closing the parking layer.
        parking.state = "normal"
        api.session.set_layer_state(parking)
    end
    api.call("block.close", {session_id = session_id, block_id = picker})
    if not restored then error(restore_err) end
    if not ok then error(err) end
end

function M.open(api, ctx, options)
    assert(ctx.session_id and ctx.block_id, "fastcopy: no terminal pane context")
    local view, err = api.session.view{session_id = ctx.session_id}
    assert(view, err)
    local window, layer, bounds = locate(view, ctx.block_id)
    assert(window, "fastcopy: target pane is not placed")
    local watched = options.rex_path ~= nil
    local native = watched and layer.kind == "tiled"
    local zoomed = layer.kind == "tiled" and window.zoomed_block_id == ctx.block_id
    if zoomed then bounds = {0, 0, 1, 1} end
    local content, dimensions = capture_screen(api, ctx.session_id, ctx.block_id)
    local temp, temp_err = api.exec({"/usr/bin/mktemp", "-t", "rex-fastcopy"})
    assert(temp and temp.ok, temp_err or "fastcopy: cannot create snapshot")
    local path = temp.stdout:gsub("[\r\n]+$", "")
    local ready = watched and path .. ".ready" or path
    local picker
    local ok, result = pcall(function()
        local file = assert(io.open(path, "w"))
        local wrote, write_err = file:write(content)
        local closed, close_err = file:close()
        assert(wrote and closed, write_err or close_err)

        local command = {options.directory .. "/target/release/rex-fastcopy",
            "--snapshot", ready, "--pane", ctx.block_id}
        if watched then
            command[#command + 1] = "--wait-for-snapshot"
            command[#command + 1] = "--keep-frame-on-exit"
        end
        for _, arg in ipairs(options.args or {}) do command[#command + 1] = arg end

        local block = {
            flavor = "com.superlogical.terminal.shell", label = "Fastcopy",
            options = {shell = "none", command = command,
                size = {columns = dimensions.columns, rows = dimensions.rows},
                exit = {on_completion = not watched},
            },
        }
        -- A floating source already uses the same insets as the picker.
        -- For tiled panes, use this layer only to hold the swapped-out terminal.
        local floating, layer_err = api.session.new_layer{
            session_id = ctx.session_id, window_id = window.window_id,
            bounds = bounds, focus = not native, layout = {block = block},
        }
        assert(floating, layer_err)
        picker = floating.block_ids and floating.block_ids[1]
        if native then
            assert(api.session.set_layer_state{session_id = ctx.session_id,
                layer_id = floating.layer_id, state = "minimized"})
        end
        if watched then
            local watcher_args = assert(api.json.encode{
                core = options.directory .. "/lua/rex-fastcopy/core.lua",
                session = ctx.session_id, source = ctx.block_id, picker = assert(picker),
                layer = assert(floating.layer_id), source_layer = layer.layer_id, rex_path = options.rex_path,
                native = native, zoomed = zoomed,
                snapshot = path, ready = ready,
            })
            local watcher, watch_err = api.exec.start({
                options.rex_path, "--autostart=false", "do", "-s", ctx.session_id, "-e", run_picker,
                "--args", watcher_args,
            }, {detach = true, stdout = false, stderr = false})
            assert(watcher, watch_err)
        end
        return floating
    end)
    if not ok then
        if picker then
            pcall(api.call, "block.close", {session_id = ctx.session_id, block_id = picker})
        end
        os.remove(path)
        if watched then os.remove(ready) end
        error(result)
    end
    return result
end

return M
