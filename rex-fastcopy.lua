-- Named module entry point for rexpack and ordinary require().
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local directory = source:match("^(.*)/") or "."
return dofile(directory .. "/init.lua")
