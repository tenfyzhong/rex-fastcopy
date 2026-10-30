package.path = "./?.lua;./.test-deps/share/lua/5.5/?.lua;" .. package.path
local lu = require("luaunit")
local Guard = require("guard")

TestGuard = {}
function TestGuard:setUp()
    self.layers = {{layer_id = "picker"}}
    self.api = {session = {view = function()
        return {windows = {{layers = self.layers}}}
    end}}
    self.guard = Guard.new(self.api)
    self.ctx = {client_id = "client", session_id = "source-session", block_id = "source"}
end
function TestGuard:testBlocksDuringStartupAndWhilePickerExists()
    lu.assertFalse(self.guard:active(self.ctx))
    self.guard:begin(self.ctx)
    lu.assertTrue(self.guard:active(self.ctx))
    self.guard:opened(self.ctx, {layer_id = "picker"})
    lu.assertTrue(self.guard:active(self.ctx))
    lu.assertFalse(self.guard:active({client_id = "other"}))
end
function TestGuard:testGuardFollowsClientEvenIfNativeUIChangesSession()
    self.guard:begin(self.ctx)
    self.guard:opened(self.ctx, {layer_id = "picker"})
    self.api.session.view = function(args)
        lu.assertEquals(args.session_id, "source-session")
        return {windows = {{layers = self.layers}}}
    end
    lu.assertTrue(self.guard:active({client_id = "client", session_id = "other-session"}))
end
function TestGuard:testClosedPickerReleasesNavigationWithoutPersistentMode()
    self.guard:begin(self.ctx)
    self.guard:opened(self.ctx, {layer_id = "picker"})
    self.layers = {}
    lu.assertFalse(self.guard:active(self.ctx))
end
function TestGuard:testFailedStartupCanReleaseGuard()
    self.guard:begin(self.ctx)
    self.guard:clear(self.ctx)
    lu.assertFalse(self.guard:active(self.ctx))
end
function TestGuard:testUnavailableSessionDoesNotPermanentlyLockNavigation()
    self.guard:begin(self.ctx)
    self.guard:opened(self.ctx, {layer_id = "picker"})
    self.api.session.view = function() return nil, "session not found" end
    lu.assertFalse(self.guard:active(self.ctx))
end
os.exit(lu.LuaUnit.run())
