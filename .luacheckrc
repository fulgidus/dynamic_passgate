-- .luacheckrc for dynamic_passgate

-- Lua 5.1 (LuaJIT) used by Luanti
std = "lua51"

-- No global writes in this mod
allow_defined_top = false

-- Read-only globals provided by the Luanti engine
read_globals = {
    "core",

    -- Optional dependency globals (may or may not exist at runtime)
    "sfinv_buttons",
    "sfinv",
}

-- No globals are set by this mod
globals = {}

-- Line length
max_line_length = 120
