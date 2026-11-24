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
return dofile(rex.args.core).run_in_pane(rex, rex.args)
]]

function M.run_in_pane(api, args)
    local session_id, source, picker = args.session, args.source, args.picker
    local function move_beside(block, anchor, side, ratio)
        return api.session.move_block{
            session_id = session_id, block_id = block, anchor_block_id = anchor,
            direction = "horizontal", side = side, ratio = ratio,
        }
    end
    local function focus(block)
        local target = {session_id = session_id, block_id = block}
        if args.zoomed then
            target.zoom = true
            return api.session.zoom_block(target)
        end
        return api.session.focus_block(target)
    end
    local claimed_source, detached_source = false, false
    local ok, err = pcall(function()
        local attached = assert(api.session.attach{session_id = session_id})
        local view = attached.view
        local window, layer = locate(view, source)
        assert(layer and layer.layer_id == args.layer and window.window_id == args.window
            and window.focused_block_id == source
            and view.active_window_id == window.window_id, "fastcopy: source pane changed")
        -- Keep the original terminal size while the temporary split is collapsed.
        local claimed = assert(api.call("session.own_block", {
            session_id = session_id, block_ids = {source}, mode = "take",
        }))
        assert(claimed.blocks[1].owner == attached.client_id, "fastcopy: could not preserve the source grid")
        claimed_source = true
        assert(move_beside(picker, source, "after", 0.9))
        assert(api.session.detach_block{session_id = session_id, block_id = source})
        detached_source = true
        assert(focus(picker))
        assert(os.rename(args.snapshot, args.ready))
        api.exec({args.rex_path, "--autostart=false", "wait", "-s", session_id, picker})
    end)
    os.remove(args.snapshot)
    os.remove(args.ready)

    local restored, restore_focus = pcall(function()
        local still_focused = false
        if detached_source then
            local view = assert(api.session.view{session_id = session_id})
            local window, layer = locate(view, picker)
            local anchor
            if layer and layer.layer_id == args.layer and window.window_id == args.window then
                anchor = picker
                still_focused = view.active_window_id == window.window_id and window.focused_block_id == picker
            else
                -- If Rex closed the picker directly, use a surviving pane in
                -- the original tab to make the source terminal visible again.
                for _, candidate in ipairs(view.windows or {}) do
                    if candidate.window_id == args.window then
                        anchor = candidate.focused_block_id
                        break
                    end
                end
            end
            assert(anchor, "fastcopy: no pane available to restore the source terminal")
            -- Keep the restored pane near its final width while Rex removes
            -- the temporary split. Focus the source once the split is gone.
            assert(move_beside(source, anchor, "before", anchor == picker and 0.999 or 0.9))
        end
        api.call("block.close", {session_id = session_id, block_id = picker})
        return still_focused
    end)
    if claimed_source then
        api.call("session.disown_block", {session_id = session_id, block_ids = {source}})
    end
    if not restored then error(restore_focus) end
    if restore_focus then focus(source) end
    if not ok then error(err) end
end

function M.open(api, ctx, options)
    assert(ctx.session_id and ctx.block_id, "fastcopy: no terminal pane context")
    local view, err = api.session.view{session_id = ctx.session_id}
    assert(view, err)
    local window, layer, bounds = locate(view, ctx.block_id)
    assert(window, "fastcopy: target pane is not placed")
    local zoomed = layer.kind == "tiled" and window.zoomed_block_id == ctx.block_id
    local content, dimensions = capture_screen(api, ctx.session_id, ctx.block_id)
    local temp, temp_err = api.exec({"/usr/bin/mktemp", "-t", "rex-fastcopy"})
    assert(temp and temp.ok, temp_err or "fastcopy: cannot create snapshot")
    local path = temp.stdout:gsub("[\r\n]+$", "")
    local picker
    local ok, result = pcall(function()
        local file = assert(io.open(path, "w"))
        local wrote, write_err = file:write(content)
        local closed, close_err = file:close()
        assert(wrote and closed, write_err or close_err)

        local native = options.rex_path ~= nil
        local ready = native and path .. ".ready" or path
        local command = {options.directory .. "/target/release/rex-fastcopy",
            "--snapshot", ready, "--pane", ctx.block_id}
        if native then
            command[#command + 1] = "--wait-for-snapshot"
            command[#command + 1] = "--keep-frame-on-exit"
        end
        for _, arg in ipairs(options.args or {}) do command[#command + 1] = arg end

        local block = {
            flavor = "com.superlogical.terminal.shell", label = "Fastcopy",
            options = {shell = "none", command = command,
                size = {columns = dimensions.columns, rows = dimensions.rows},
                exit = {on_completion = not native},
            },
        }
        if not native then
            local floating, layer_err = api.session.new_layer{
                session_id = ctx.session_id, window_id = window.window_id,
                bounds = bounds, focus = true, layout = {block = block},
            }
            assert(floating, layer_err)
            return floating
        end

        block.session_id = ctx.session_id
        local created, create_err = api.session.new_block(block)
        assert(created, create_err)
        picker = assert(created.block_id)
        local watcher_args = assert(api.json.encode{
            core = options.directory .. "/lua/rex-fastcopy/core.lua",
            session = ctx.session_id, source = ctx.block_id, picker = picker,
            window = window.window_id, layer = assert(layer.layer_id),
            rex_path = options.rex_path, zoomed = zoomed, snapshot = path, ready = ready,
        })
        local watcher, watch_err = api.exec.start({
            options.rex_path, "--autostart=false", "do", "-s", ctx.session_id, "-e", run_picker,
            "--args", watcher_args,
        }, {detach = true, stdout = false, stderr = false})
        assert(watcher, watch_err)
        return {block_ids = {picker}}
    end)
    if not ok then
        if picker then
            pcall(api.call, "block.close", {session_id = ctx.session_id, block_id = picker})
        end
        os.remove(path)
        error(result)
    end
    return result
end

return M
