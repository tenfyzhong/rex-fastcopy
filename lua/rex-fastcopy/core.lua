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
                return window.window_id, rect, window
            end
        end
    end
    error("fastcopy: target pane is not placed")
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

local function visit(node, callback)
    if node.block_id then callback(node) end
    if node.split then
        visit(node.split.before, callback)
        visit(node.split.after, callback)
    end
end

-- Rex macOS 1497: tiled text has a 6 pt top inset absent in floating
-- layers. Values are device pixels (the tested client uses a 2x display).
function M.overlay_bounds(dimensions, rect, inset_y)
    inset_y = inset_y or 12
    if not dimensions.cell_height_px or dimensions.cell_height_px == 0 then
        return {0, 0, 1, 1}
    end
    -- Size exposes integral cells, not the sub-cell remainder. Use its midpoint;
    -- this was verified against the native text baseline on the current display.
    local height = ((dimensions.rows + 0.5) * dimensions.cell_height_px + 2 * inset_y) / rect[4]
    local top = inset_y / height
    return {0, top, 1, 1 - top}
end

function M.open(api, ctx, options)
    assert(ctx.session_id and ctx.block_id, "fastcopy: no terminal pane context")
    local view, err = api.session.view{session_id = ctx.session_id}
    assert(view, err)
    local window_id, bounds, window = locate(view, ctx.block_id)
    local content, dimensions = capture_screen(api, ctx.session_id, ctx.block_id)
    local padding_columns = 0
    if dimensions.cell_width_px and dimensions.cell_width_px > 0 then
        padding_columns = 2 * (options.inset_x_px or 16) / dimensions.cell_width_px
    end
    local paths = {}
    local function snapshot(text)
        local temp, temp_err = api.exec({"/usr/bin/mktemp", "-t", "rex-fastcopy"})
        assert(temp and temp.ok, temp_err or "fastcopy: cannot create snapshot")
        local path = temp.stdout:gsub("[\r\n]+$", "")
        paths[#paths + 1] = path
        local file = assert(io.open(path, "w"))
        local wrote, write_err = file:write(text)
        local closed, close_err = file:close()
        assert(wrote and closed, write_err or close_err)
        return path
    end
    local ok, result = pcall(function()
        local path = snapshot(content)
        local command = {
            options.directory .. "/target/release/rex-fastcopy",
            "--snapshot", path, "--pane", ctx.block_id,
            "--region", table.concat(bounds, ","),
        }
        if dimensions.cell_width_px and dimensions.cell_width_px > 0 then
            command[#command + 1] = "--padding-columns"
            command[#command + 1] = tostring(padding_columns)
        end
        -- Rex 1497 clips offset layers. A window-sized surface retains all
        -- pane positions; neighboring panes are frozen snapshots, never moved.
        for _, source_layer in ipairs(window.layers or {}) do
            if source_layer.layout then
                visit(source_layer.layout, function(node)
                    if node.block_id ~= ctx.block_id then
                        local text = capture_screen(api, ctx.session_id, node.block_id)
                        command[#command + 1] = "--background"
                        command[#command + 1] = table.concat(node.rect, ",") .. ":" .. snapshot(text)
                    end
                end)
            end
        end
        if options.rex_path then
            command[#command + 1] = "--rex"
            command[#command + 1] = options.rex_path
            command[#command + 1] = "--session"
            command[#command + 1] = ctx.session_id
        end
        for _, arg in ipairs(options.args or {}) do command[#command + 1] = arg end
        local layer, layer_err = api.session.new_layer{
            session_id = ctx.session_id, window_id = window_id,
            -- The source layout and terminal dimensions are never mutated.
            bounds = M.overlay_bounds(dimensions, bounds, options.inset_y_px), focus = true,
            layout = {block = {
                flavor = "com.superlogical.terminal.shell", label = "Fastcopy",
                options = {shell = "none", command = command,
                    size = {
                        columns = math.floor(dimensions.columns / bounds[3] + padding_columns + 0.5),
                        rows = math.floor(dimensions.rows / bounds[4] + 0.5),
                    },
                    exit = {on_completion = true},
                },
            }},
        }
        assert(layer, layer_err)
        return layer
    end)
    if not ok then
        for _, path in ipairs(paths) do os.remove(path) end
        error(result)
    end
    return result
end

return M
