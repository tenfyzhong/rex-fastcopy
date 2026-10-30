local M = {}

function M.new(api)
    local states = {}
    local guard = {}
    local function key(ctx) return assert(ctx.client_id, "fastcopy: client context required") end
    function guard:begin(ctx)
        states[key(ctx)] = {session_id = ctx.session_id, starting = true}
    end
    function guard:opened(ctx, result)
        states[key(ctx)] = {session_id = ctx.session_id, layer_id = result.layer_id}
    end
    function guard:clear(ctx) states[key(ctx)] = nil end
    function guard:active(ctx)
        local state = states[key(ctx)]
        if not state then return false end
        if state.starting then return true end
        local view = api.session.view{session_id = state.session_id}
        for _, window in ipairs(view and view.windows or {}) do
            for _, layer in ipairs(window.layers or {}) do
                if layer.layer_id == state.layer_id then return true end
            end
        end
        -- No persistent client mode: closing/crashing the helper automatically
        -- releases the guard on the next navigation command.
        states[key(ctx)] = nil
        return false
    end
    return guard
end

return M
