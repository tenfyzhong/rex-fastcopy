package.path = "./lua/?.lua;./lua/?/init.lua;./.test-deps/share/lua/5.5/?.lua;" .. package.path
local lu = require("luaunit")
local Guard = require("rex-fastcopy.guard")

TestGuard = {}
function TestGuard:setUp()
    self.blocks = {{block_id = "picker", placement = "detached"}}
    self.api = {session = {list_blocks = function()
        return {blocks = self.blocks}
    end}}
    self.guard = Guard.new(self.api)
    self.ctx = {client_id = "client", session_id = "source-session", block_id = "source"}
end
function TestGuard:testBlocksDuringStartupAndWhilePickerExists()
    lu.assertFalse(self.guard:active(self.ctx))
    self.guard:begin(self.ctx)
    lu.assertTrue(self.guard:active(self.ctx))
    self.guard:opened(self.ctx, {block_ids = {"picker"}})
    lu.assertTrue(self.guard:active(self.ctx))
    lu.assertFalse(self.guard:active({client_id = "other"}))
end
function TestGuard:testGuardFollowsClientEvenIfNativeUIChangesSession()
    self.guard:begin(self.ctx)
    self.guard:opened(self.ctx, {block_ids = {"picker"}})
    self.api.session.list_blocks = function(args)
        lu.assertEquals(args.session_id, "source-session")
        return {blocks = self.blocks}
    end
    lu.assertTrue(self.guard:active({client_id = "client", session_id = "other-session"}))
end
function TestGuard:testClosedPickerReleasesNavigationWithoutPersistentMode()
    self.guard:begin(self.ctx)
    self.guard:opened(self.ctx, {block_ids = {"picker"}})
    self.blocks = {}
    lu.assertFalse(self.guard:active(self.ctx))
end
function TestGuard:testOtherBlocksDoNotKeepGuardActive()
    self.blocks[2] = {block_id = "other"}
    self.guard:begin(self.ctx)
    self.guard:opened(self.ctx, {block_ids = {"picker"}})
    lu.assertTrue(self.guard:active(self.ctx))
    table.remove(self.blocks, 1)
    lu.assertFalse(self.guard:active(self.ctx))
end
function TestGuard:testFailedStartupCanReleaseGuard()
    self.guard:begin(self.ctx)
    self.guard:clear(self.ctx)
    lu.assertFalse(self.guard:active(self.ctx))
end
function TestGuard:testUnavailableSessionDoesNotPermanentlyLockNavigation()
    self.guard:begin(self.ctx)
    self.guard:opened(self.ctx, {block_ids = {"picker"}})
    self.api.session.list_blocks = function() return nil, "session not found" end
    lu.assertFalse(self.guard:active(self.ctx))
end
os.exit(lu.LuaUnit.run())
