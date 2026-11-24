local M = {}

function M.new(api)
    local states = {}
    local guard = {}
    local function key(ctx) return assert(ctx.client_id, "fastcopy: client context required") end
    function guard:begin(ctx)
        states[key(ctx)] = {session_id = ctx.session_id, starting = true}
    end
    function guard:opened(ctx, result)
        states[key(ctx)] = {
            session_id = ctx.session_id,
            picker_id = result.block_ids and result.block_ids[1],
        }
    end
    function guard:is_picker(ctx)
        local state = states[ctx.client_id]
        return state ~= nil and state.picker_id ~= nil
            and state.picker_id == ctx.block_id and state.session_id == ctx.session_id
    end
    function guard:clear(ctx) states[key(ctx)] = nil end
    function guard:active(ctx)
        local state = states[key(ctx)]
        if not state then return false end
        if state.starting then return true end
        local result = api.session.list_blocks{session_id = state.session_id}
        for _, block in ipairs(result and result.blocks or {}) do
            if state.picker_id == block.block_id then return true end
        end
        -- No persistent client mode: closing/crashing the helper automatically
        -- releases the guard on the next navigation command.
        states[key(ctx)] = nil
        return false
    end
    return guard
end

return M
