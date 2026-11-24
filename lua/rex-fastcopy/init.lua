local source = debug.getinfo(1, "S").source:gsub("^@", "")
local directory = assert(source:match("^(.*)/lua/rex%-fastcopy/init%.lua$"),
    "fastcopy: cannot locate plugin root")
local core = require("rex-fastcopy.core")
local guard = require("rex-fastcopy.guard").new(rex)

rex.action{
    name = "fastcopy",
    title = "Fastcopy: Copy Highlighted Text",
    description = "Type a label to copy; Tab selects multiple; Escape cancels.",
    run = function(ctx)
        if guard:active(ctx) then return end
        guard:begin(ctx)
        local ok, result = pcall(core.open, rex, ctx, {
            directory = directory,
            rex_path = os.getenv("HOME") .. "/Library/Application Support/com.superlogical.rex/"
                .. "RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
            args = {"--regex", "word:(?:\\.|\\b)\\S+\\b"},
        })
        if not ok then guard:clear(ctx); error(result) end
        guard:opened(ctx, result)
        -- Rex consumes Escape to exit an active key mode before the terminal
        -- receives it. Clear passthrough mode so one Escape cancels the picker.
        rex.client.queue("client.mode.exit_all")
        return result
    end,
}
rex.bind("prefix/f", "fastcopy")
rex.bind("terminal_prefix/f", "fastcopy")

local function cancel_picker(ctx)
    if not guard:is_picker(ctx) then return false end
    -- Send the picker's existing Ctrl+C cancel input directly. A bare Escape
    -- can be consumed by key modes or combined with another terminal sequence.
    local written, err = rex.block.call("com.superlogical.terminal", "write", {
        session_id = ctx.session_id, block_id = ctx.block_id, data = "\3",
    })
    if not written then error(err or "fastcopy: could not cancel the picker", 0) end
    return true
end

rex.action{
    name = "fastcopy_escape",
    title = "Fastcopy: Cancel or Run Escape Binding",
    args = {action = "string", original_args = "object?"},
    run = function(ctx, args)
        if cancel_picker(ctx) then return end
        if args.action:find(".", 1, true) then
            return rex.client.queue(args.action, args.original_args)
        end
        local result, err = rex.invoke(args.action, args.original_args)
        if err then error(err, 0) end
        return result
    end,
}

-- Guard actions rather than entering a persistent mode. A finished/crashed
-- helper cannot leave normal typing trapped in a stale exclusive key table.
rex.action{
    name = "fastcopy_guard",
    title = "Fastcopy: Guard Navigation",
    args = {action = "string", original_args = "object?"},
    run = function(ctx, args)
        if not guard:active(ctx) then
            rex.client.queue(args.action, args.original_args)
        end
    end,
}
local function protect(key, action, args)
    rex.bind(key, "fastcopy_guard", {action = action, original_args = args})
end
local configured = {}
local normal_escape, terminal_escape
for _, binding in ipairs(rex.bindings()) do
    local action = binding.action or ""
    local key = (binding.mode and binding.mode .. "/" or "") .. binding.key
    configured[key] = true
    local escape = binding.key == "esc" or binding.key == "escape"
    if escape and not binding.mode then
        normal_escape = binding
    elseif escape and binding.mode == "terminal" then
        terminal_escape = binding
    elseif (action:match("^pane%.") and action ~= "pane.send_key")
        or action:match("^session%.") or action:match("^client%.tab%.")
        or action:match("^client%.window%.") or action:match("^client%.sidebar%.")
        or action == "client.mode.enter" or action == "client.config.reload"
        or action == "client.palette.toggle" then
        protect(key, action, binding.args)
    end
end
local function bind_escape(key, original)
    rex.bind(key, "fastcopy_escape", {action = original.action, original_args = original.args})
end
if normal_escape and normal_escape.action then
    bind_escape("escape", normal_escape)
else
    -- Rex continues through earlier Lua functions and then to the terminal.
    rex.bind("escape", cancel_picker)
end
if terminal_escape and terminal_escape.action then
    bind_escape("terminal/" .. terminal_escape.key, terminal_escape)
end
-- Native macOS routes which do not appear in rex.bindings(). Configured
-- bindings above retain their original action/arguments.
local native = {
    {"cmd+k", "session.switch"},
    {"cmd+t", "client.tab.new"},
    {"cmd+n", "client.window.new"},
    {"cmd+w", "client.close"},
    {"shift+cmd+w", "client.window.close"},
    {"shift+cmd+p", "client.palette.toggle"},
    {"ctrl+tab", "client.tab.next"},
    {"shift+ctrl+tab", "client.tab.previous"},
    {"shift+cmd+[", "client.tab.previous"},
    {"shift+cmd+]", "client.tab.next"},
    {"cmd+d", "pane.split", {direction = "right"}},
    {"shift+cmd+d", "pane.split", {direction = "down"}},
}
for index = 1, 9 do
    native[#native + 1] = {"cmd+" .. index, "client.tab.goto", {index = index}}
end
for _, binding in ipairs(native) do
    if not configured[binding[1]] then protect(binding[1], binding[2], binding[3]) end
end
