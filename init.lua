-- Dynamic Passgate
-- Invite-only server gate with dynamic per-user passwords
--
-- Flow:
-- 1. Unknown player connects -> mod creates account with templated password
-- 2. Engine authenticates against that hash (wrong password = rejected)
-- 3. On successful join, mod checks if player is verified
-- 4. Unverified: strip privs, freeze, show dismissable modal with countdown
-- 5. Player changes password -> verified, granted configured privs
-- 6. Timer expires -> kicked, strike incremented, account purged
-- 7. Max strikes -> blocked permanently
--
-- Admin panel accessible via /gate command or inventory button.
-- Requires "server" priv OR "passgate_admin" priv.

local MOD_VERSION = "1.0.3"

-- ============================================================================
-- Persistent storage
-- ============================================================================

local storage = core.get_mod_storage()

-- ============================================================================
-- Defaults and settings
-- ============================================================================

local DEFAULTS = {
    password_template  = "${name}-wants-in",
    countdown_seconds  = "120",
    max_strikes        = "3",
    reminder_interval  = "10",
    admin_email        = "",
    server_title       = "",
    verified_privs     = "interact,shout,fly,fast,noclip,give,creative,basic_privs,teleport,debug",
    show_inventory_button = "true",
}

--- Read a setting with fallback chain: mod_storage -> minetest.conf -> default
local function get_setting(key)
    local val = storage:get_string("setting:" .. key)
    if val ~= "" then return val end
    val = core.settings:get("dynamic_passgate." .. key)
    if val then return val end
    return DEFAULTS[key]
end

--- Write a setting to mod_storage (takes effect immediately)
local function set_setting(key, value)
    storage:set_string("setting:" .. key, value)
end

--- Get a numeric setting
local function get_setting_int(key)
    return tonumber(get_setting(key)) or tonumber(DEFAULTS[key])
end

--- Get a boolean setting
local function get_setting_bool(key)
    return get_setting(key) == "true"
end

--- Get the server title: override -> server_name setting -> fallback
local function get_server_title()
    local title = get_setting("server_title")
    if title ~= "" then return title end
    return core.settings:get("server_name") or "this server"
end

--- Get the admin email, or nil if not set
local function get_admin_email()
    local email = get_setting("admin_email")
    if email ~= "" then return email end
    return nil
end

--- Parse verified_privs CSV into a table
local function get_verified_privs()
    local csv = get_setting("verified_privs")
    local privs = {}
    for priv in csv:gmatch("[^,%s]+") do
        privs[priv] = true
    end
    return privs
end

-- ============================================================================
-- Template engine
-- ============================================================================

local MONTH_ABBR = {
    "jan", "feb", "mar", "apr", "may", "jun",
    "jul", "aug", "sep", "oct", "nov", "dec",
}
local MONTH_FULL = {
    "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
}

--- Expand a password template with variable substitution
local function expand_template(template, player_name)
    local t = os.date("*t")
    local m_idx = t.month

    -- Build substitution table (longest keys first to avoid partial matches)
    local vars = {
        ["${name}"]  = player_name:lower(),
        ["${NAME}"]  = player_name,
        ["${server}"] = get_server_title(),
        ["${dd}"]    = string.format("%02d", t.day),
        ["${d}"]     = tostring(t.day),
        ["${mmmm}"]  = MONTH_FULL[m_idx],
        ["${MMMM}"]  = MONTH_FULL[m_idx]:sub(1, 1):upper() .. MONTH_FULL[m_idx]:sub(2),
        ["${mmm}"]   = MONTH_ABBR[m_idx],
        ["${MMM}"]   = MONTH_ABBR[m_idx]:sub(1, 1):upper() .. MONTH_ABBR[m_idx]:sub(2),
        ["${mm}"]    = string.format("%02d", t.month),
        ["${m}"]     = tostring(t.month),
        ["${yyyy}"]  = tostring(t.year),
        ["${yy}"]    = string.format("%02d", t.year % 100),
    }

    -- Sort by key length descending to prevent partial matches
    -- (e.g. ${mmmm} must be replaced before ${mmm} before ${mm} before ${m})
    local keys = {}
    for k in pairs(vars) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return #a > #b end)

    local result = template
    for _, k in ipairs(keys) do
        -- Use plain string replacement (gsub pattern escaping)
        result = result:gsub(k:gsub("([%${}])", "%%%1"), vars[k])
    end

    return result
end

-- ============================================================================
-- Admin privilege
-- ============================================================================

core.register_privilege("passgate_admin", {
    description = "Allows access to the Dynamic Passgate admin panel",
    give_to_singleplayer = false,
    give_to_admin = true,
})

--- Check if a player has admin access to passgate
local function has_admin_access(name)
    return core.check_player_privs(name, { server = true })
        or core.check_player_privs(name, { passgate_admin = true })
end

-- ============================================================================
-- Admin bypass
-- ============================================================================

local server_admin = core.settings:get("name") or ""

-- ============================================================================
-- Player storage helpers
-- ============================================================================

local function is_verified(name)
    if name == server_admin then
        return true
    end
    return storage:get_string("verified:" .. name) == "true"
end

local function set_verified(name)
    storage:set_string("verified:" .. name, "true")
    storage:set_string("strikes:" .. name, "")
end

local function get_strikes(name)
    local s = storage:get_string("strikes:" .. name)
    return tonumber(s) or 0
end

local function add_strike(name)
    local strikes = get_strikes(name) + 1
    storage:set_string("strikes:" .. name, tostring(strikes))
    return strikes
end

local function reset_strikes(name)
    storage:set_string("strikes:" .. name, "")
end

local function is_blocked(name)
    return storage:get_string("blocked:" .. name) == "true"
end

local function get_block_reason(name)
    local reason = storage:get_string("block_reason:" .. name)
    if reason ~= "" then return reason end
    return nil
end

local function set_blocked(name, reason)
    storage:set_string("blocked:" .. name, "true")
    storage:set_string("block_reason:" .. name, reason or "")
end

local function unset_blocked(name)
    storage:set_string("blocked:" .. name, "")
    storage:set_string("block_reason:" .. name, "")
end

--- Build ban message shown to the player (kick + pre-join rejection)
local function build_ban_message(name)
    local msg = "You have been banned from " .. get_server_title() .. "."
    local reason = get_block_reason(name)
    if reason then
        msg = msg .. "\nReason: " .. reason
    end
    local email = get_admin_email()
    if email then
        msg = msg .. "\nContact " .. email .. " to ask to be reinstated."
    end
    return msg
end

--- Track a player name in mod_storage so we can list them later
--- (auth may be deleted for blocked players, so we can't rely on auth alone)
local function track_player(name)
    local known_csv = storage:get_string("known_players")
    -- Check if already tracked
    for existing in known_csv:gmatch("[^,]+") do
        if existing == name then return end
    end
    -- Append
    if known_csv == "" then
        storage:set_string("known_players", name)
    else
        storage:set_string("known_players", known_csv .. "," .. name)
    end
end

--- Get a list of all known players from mod_storage and auth database
local function get_all_known_players()
    local players = {}
    local seen = {}

    -- 1. Scan auth database for players with accounts
    local auth_handler = core.get_auth_handler()
    if auth_handler.iterate then
        for name in auth_handler.iterate() do
            local lname = name:lower()
            if not seen[lname] then
                seen[lname] = true
                track_player(lname)  -- ensure they're tracked
                local status = "unverified"
                if is_blocked(lname) then
                    status = "blocked"
                elseif is_verified(lname) then
                    status = "verified"
                end
                local is_gate_admin = core.check_player_privs(lname,
                    { passgate_admin = true })
                players[#players + 1] = {
                    name = lname,
                    status = status,
                    strikes = get_strikes(lname),
                    is_gate_admin = is_gate_admin,
                }
            end
        end
    end

    -- 2. Also check mod_storage for players we've tracked
    --    (catches blocked players whose auth was deleted)
    --    mod_storage has no iterator, so we check verified/blocked/known keys
    --    by scanning players we've seen via the known: prefix.
    --    Since mod_storage has no key iterator, we maintain a CSV list.
    local known_csv = storage:get_string("known_players")
    if known_csv ~= "" then
        for lname in known_csv:gmatch("[^,]+") do
            if not seen[lname] and lname ~= "" then
                seen[lname] = true
                local status = "unverified"
                if is_blocked(lname) then
                    status = "blocked"
                elseif is_verified(lname) then
                    status = "verified"
                end
                -- No auth entry = no privs
                players[#players + 1] = {
                    name = lname,
                    status = status,
                    strikes = get_strikes(lname),
                    is_gate_admin = false,
                }
            end
        end
    end

    -- Sort alphabetically
    table.sort(players, function(a, b) return a.name < b.name end)
    return players
end

-- ============================================================================
-- Runtime state
-- ============================================================================

-- pending[name] = { remaining, modal_dismissed, reminder_timer }
local pending = {}

-- Monotonic clock driven by globalstep
local server_clock = 0

-- Admin panel state per admin: which tab, selected player index
local admin_state = {}

local FORMSPEC_GATE = "dynamic_passgate:gate"
local FORMSPEC_ADMIN = "dynamic_passgate:admin"
local FORMSPEC_BLOCK_CONFIRM = "dynamic_passgate:block_confirm"

-- ============================================================================
-- Gate formspec (dismissable modal)
-- ============================================================================

local function get_gate_formspec(name, remaining)
    local mins = math.floor(remaining / 60)
    local secs = remaining % 60
    local time_str = string.format("%dm%02ds", mins, secs)
    local template = get_setting("password_template")
    local current_pw = expand_template(template, name)
    local title = get_server_title()

    local email = get_admin_email()
    local contact_line = ""
    if email then
        contact_line = "label[1,7.4;" .. core.colorize("#888888",
            "Contact: " .. core.formspec_escape(email)) .. "]"
    end

    return "formspec_version[6]"
        .. "size[12,8.5]"
        .. "no_prepend[]"
        .. "bgcolor[#000000CC;true]"
        .. "label[1,1;Welcome to " .. core.formspec_escape(title) .. "]"
        .. "label[1,2.0;You must change your password to continue.]"
        .. "label[1,2.8;Press Escape to dismiss, then open chat (T key) and type:]"
        .. "label[1,3.8;" .. core.colorize("#FFFF55",
            "/password " .. core.formspec_escape(current_pw)
            .. " <your-new-password>") .. "]"
        .. "label[1,5.0;You can dismiss this dialog with Escape. Reminders will follow.]"
        .. "label[1,6.0;Time remaining: " .. core.colorize("#FF6B6B", time_str) .. "]"
        .. "label[1,6.8;" .. core.colorize("#888888",
            "Non-compliance will result in disconnection.") .. "]"
        .. contact_line
end

local function show_gate(player, remaining)
    local name = player:get_player_name()
    core.show_formspec(name, FORMSPEC_GATE, get_gate_formspec(name, remaining))
end

-- ============================================================================
-- Admin panel formspecs
-- ============================================================================

local function get_admin_settings_formspec()
    local pw_template     = core.formspec_escape(get_setting("password_template"))
    local countdown       = get_setting("countdown_seconds")
    local max_strikes     = get_setting("max_strikes")
    local reminder        = get_setting("reminder_interval")
    local email           = core.formspec_escape(get_setting("admin_email"))
    local title           = core.formspec_escape(get_setting("server_title"))
    local privs           = core.formspec_escape(get_setting("verified_privs"))
    local inv_btn         = get_setting_bool("show_inventory_button")

    -- Template variable reference
    local help = "${name} ${NAME} ${server} ${d} ${dd} ${m} ${mm}\n"
        .. "${mmm} ${mmmm} ${MMM} ${MMMM} ${yy} ${yyyy}"

    return "formspec_version[6]"
        .. "size[14,12.5]"
        .. "tabheader[0,0;tabs;Settings,Players,Status;1;false;true]"

        .. "label[0.5,0.8;Password template:]"
        .. "field[5,0.4;8.5,0.7;password_template;;" .. pw_template .. "]"
        .. "label[0.5,1.6;" .. core.colorize("#888888", "Variables: " .. help) .. "]"

        .. "label[0.5,2.6;Countdown (seconds):]"
        .. "field[5,2.2;3,0.7;countdown_seconds;;" .. countdown .. "]"

        .. "label[0.5,3.4;Max strikes:]"
        .. "field[5,3.0;3,0.7;max_strikes;;" .. max_strikes .. "]"

        .. "label[0.5,4.2;Reminder interval (s):]"
        .. "field[5,3.8;3,0.7;reminder_interval;;" .. reminder .. "]"

        .. "label[0.5,5.0;Admin email:]"
        .. "field[5,4.6;8.5,0.7;admin_email;;" .. email .. "]"

        .. "label[0.5,5.8;Server title override:]"
        .. "field[5,5.4;8.5,0.7;server_title;;" .. title .. "]"
        .. "label[5,6.2;" .. core.colorize("#888888",
            "Leave empty to use server_name from minetest.conf") .. "]"

        .. "label[0.5,7.0;Verified privileges:]"
        .. "field[5,6.6;8.5,0.7;verified_privs;;" .. privs .. "]"

        .. "checkbox[0.5,8.0;show_inventory_button;Show inventory button;"
            .. tostring(inv_btn) .. "]"

        .. "button[0.5,9.2;4,0.8;save_settings;Save]"
        .. "button[5,9.2;4,0.8;reset_defaults;Reset to Defaults]"

        -- Preview: show what a password would look like
        .. "label[0.5,10.5;Preview for player \"ExamplePlayer\":]"
        .. "label[0.5,11.2;" .. core.colorize("#FFFF55",
            core.formspec_escape(
                expand_template(get_setting("password_template"), "ExamplePlayer")
            )) .. "]"
end

local function get_admin_players_formspec(caller_name)
    local state = admin_state[caller_name] or {}
    local all_players = get_all_known_players()
    admin_state[caller_name] = state

    -- Apply search filter
    local filter = (state.search_filter or ""):lower()
    local players = {}
    if filter == "" then
        players = all_players
    else
        for _, p in ipairs(all_players) do
            if p.name:find(filter, 1, true) then
                players[#players + 1] = p
            end
        end
    end
    state.player_list = players

    -- Search bar
    local search_val = core.formspec_escape(state.search_filter or "")
    local search = "field[0.5,0.4;9.5,0.7;search_filter;;" .. search_val .. "]"
        .. "field_enter_after_edit[search_filter;true]"
        .. "button[10.2,0.4;3.3,0.7;do_search;Search]"

    -- Build table rows
    local rows = "tablecolumns[color;text;text;text;text]"
        .. "table[0.5,1.4;13,7;player_table;"
        .. "#AAAAAA,Name,Status,Strikes,Admin"

    for _, p in ipairs(players) do
        local color = "#FFFFFF"
        if p.status == "verified" then
            color = "#55FF55"
        elseif p.status == "blocked" then
            color = "#FF5555"
        elseif p.status == "unverified" then
            color = "#FFFF55"
        end
        local admin_mark = p.is_gate_admin and "yes" or ""
        rows = rows .. "," .. color .. ","
            .. core.formspec_escape(p.name) .. ","
            .. p.status .. ","
            .. tostring(p.strikes) .. ","
            .. admin_mark
    end

    -- Selected index (offset by 1 for header row)
    local sel = (state.selected_player_idx or 0) + 1
    rows = rows .. ";" .. sel .. "]"

    -- Action buttons (only shown if a player is selected)
    local actions = ""
    if state.selected_player_idx and state.selected_player_idx > 0 then
        local sp = players[state.selected_player_idx]
        if sp then
            local admin_btn_label = sp.is_gate_admin
                and "Revoke Admin" or "Grant Admin"
            actions = "label[0.5,8.8;Selected: "
                .. core.colorize("#FFFF55", core.formspec_escape(sp.name)) .. "]"
                .. "button[0.5,9.4;2.5,0.8;verify_player;Verify]"
                .. "button[3.2,9.4;2.5,0.8;block_player;Block]"
                .. "button[5.9,9.4;2.5,0.8;unblock_player;Unblock]"
                .. "button[8.6,9.4;2.7,0.8;reset_strikes;Reset Strikes]"
                .. "button[11.5,9.4;2,0.8;toggle_admin;" .. admin_btn_label .. "]"
        end
    end

    return "formspec_version[6]"
        .. "size[14,12.3]"
        .. "tabheader[0,0;tabs;Settings,Players,Status;2;false;true]"
        .. search
        .. rows
        .. actions
        .. "button[0.5,10.7;3,0.8;refresh_players;Refresh]"
        .. "button[3.8,10.7;3,0.8;clear_search;Clear Search]"
end

local function get_admin_status_formspec()
    local players = get_all_known_players()
    local total = #players
    local verified_count = 0
    local blocked_count = 0
    for _, p in ipairs(players) do
        if p.status == "verified" then
            verified_count = verified_count + 1
        elseif p.status == "blocked" then
            blocked_count = blocked_count + 1
        end
    end
    local unverified_count = total - verified_count - blocked_count

    -- Currently pending players
    local pending_list = ""
    local pending_count = 0
    for name, state in pairs(pending) do
        pending_count = pending_count + 1
        local r = math.ceil(state.remaining)
        local time_str = string.format("%dm%02ds", math.floor(r / 60), r % 60)
        pending_list = pending_list .. "  " .. name .. " — " .. time_str .. " remaining\n"
    end
    if pending_list == "" then
        pending_list = "  (none)"
    end

    -- Current settings summary
    local template = get_setting("password_template")
    local countdown = get_setting("countdown_seconds")
    local max_s = get_setting("max_strikes")
    local reminder = get_setting("reminder_interval")
    local title = get_server_title()

    local uptime_s = math.floor(server_clock)
    local uptime_h = math.floor(uptime_s / 3600)
    local uptime_m = math.floor((uptime_s % 3600) / 60)
    local uptime_str = string.format("%dh %dm", uptime_h, uptime_m)

    local info = "Dynamic Passgate v" .. MOD_VERSION .. "\n"
        .. "Server: " .. core.formspec_escape(title) .. "\n"
        .. "Uptime: " .. uptime_str .. "\n"
        .. "\n"
        .. core.colorize("#FFFF55", "Player Counts") .. "\n"
        .. "  Total known: " .. total .. "\n"
        .. "  Verified: " .. core.colorize("#55FF55", tostring(verified_count)) .. "\n"
        .. "  Unverified: " .. core.colorize("#FFFF55", tostring(unverified_count)) .. "\n"
        .. "  Blocked: " .. core.colorize("#FF5555", tostring(blocked_count)) .. "\n"
        .. "\n"
        .. core.colorize("#FFFF55", "Currently Pending (in countdown)") .. "\n"
        .. pending_list .. "\n"
        .. "\n"
        .. core.colorize("#FFFF55", "Active Settings") .. "\n"
        .. "  Template: " .. core.formspec_escape(template) .. "\n"
        .. "  Countdown: " .. countdown .. "s\n"
        .. "  Max strikes: " .. max_s .. "\n"
        .. "  Reminder interval: " .. reminder .. "s\n"
        .. "\n"
        .. core.colorize("#888888", "Gate Flow") .. "\n"
        .. "  1. New player connects with templated password\n"
        .. "  2. Frozen + modal shown with countdown\n"
        .. "  3. Player changes password -> verified\n"
        .. "  4. Timeout -> kicked + strike + account purged\n"
        .. "  5. Max strikes -> permanently blocked"

    return "formspec_version[6]"
        .. "size[14,12.5]"
        .. "tabheader[0,0;tabs;Settings,Players,Status;3;false;true]"
        .. "textarea[0.5,0.5;13,10.5;;;" .. core.formspec_escape(info) .. "]"
        .. "button[0.5,11.2;3,0.8;refresh_status;Refresh]"
end

local function show_admin_panel(name, tab)
    tab = tab or (admin_state[name] and admin_state[name].tab) or 1
    if not admin_state[name] then
        admin_state[name] = {}
    end
    admin_state[name].tab = tab

    local fs
    if tab == 1 then
        fs = get_admin_settings_formspec()
    elseif tab == 2 then
        fs = get_admin_players_formspec(name)
    elseif tab == 3 then
        fs = get_admin_status_formspec()
    end

    core.show_formspec(name, FORMSPEC_ADMIN, fs)
end

--- Show a confirmation dialog for blocking a player, with optional reason field
local function show_block_confirm(admin_name, target_name)
    if not admin_state[admin_name] then
        admin_state[admin_name] = {}
    end
    admin_state[admin_name].block_target = target_name

    local fs = "formspec_version[6]"
        .. "size[10,5]"
        .. "label[0.5,0.6;Block player: "
            .. core.colorize("#FF5555", core.formspec_escape(target_name)) .. "]"
        .. "label[0.5,1.3;Reason (leave empty for default):]"
        .. "field[0.5,1.7;9,0.7;block_reason;;]"
        .. "label[0.5,2.8;" .. core.colorize("#888888",
            "Default: \"Manually blocked by " .. core.formspec_escape(admin_name)
            .. "\"") .. "]"
        .. "button[0.5,3.7;4,0.8;confirm_block;Block]"
        .. "button[5.5,3.7;4,0.8;cancel_block;Cancel]"

    core.show_formspec(admin_name, FORMSPEC_BLOCK_CONFIRM, fs)
end

-- ============================================================================
-- Pre-join: auto-create accounts with templated password
-- ============================================================================

core.register_on_prejoinplayer(function(name, ip)
    local lname = name:lower()

    if is_blocked(lname) then
        return build_ban_message(lname)
    end

    local auth_handler = core.get_auth_handler()
    if auth_handler.get_auth(name) then
        return nil
    end

    -- New player: create account with templated password
    local template = get_setting("password_template")
    local raw_password = expand_template(template, name)
    local password_hash = core.get_password_hash(name, raw_password)
    auth_handler.create_auth(name, password_hash)
    core.notify_authentication_modified(name)
    track_player(lname)

    core.log("action", "[dynamic_passgate] Auto-created account for " .. name
        .. " with templated password")

    return nil
end)

-- ============================================================================
-- On auth: log failed attempts for unverified players
-- ============================================================================

core.register_on_authplayer(function(name, ip, is_success)
    if not is_success and not is_verified(name:lower()) then
        core.log("action", "[dynamic_passgate] Failed auth for unverified player "
            .. name .. " from " .. ip)
    end
end)

-- ============================================================================
-- On join: freeze unverified players and start countdown
-- ============================================================================

core.register_on_joinplayer(function(player, last_login)
    local name = player:get_player_name()
    local lname = name:lower()

    if is_verified(lname) then
        return
    end

    -- Strip all privileges
    core.set_player_privs(name, {})
    core.notify_authentication_modified(name)

    -- Freeze player
    player:set_physics_override({
        speed = 0,
        jump = 0,
        gravity = 0,
    })

    -- Start countdown
    local countdown = get_setting_int("countdown_seconds")
    pending[name] = {
        remaining = countdown,
        modal_dismissed = false,
        reminder_timer = 0,
    }

    show_gate(player, countdown)

    core.log("action", "[dynamic_passgate] Unverified player " .. name
        .. " joined, starting " .. countdown .. "s countdown")
end)

-- ============================================================================
-- Formspec handlers
-- ============================================================================

core.register_on_player_receive_fields(function(player, formname, fields)
    -- Gate modal dismiss
    if formname == FORMSPEC_GATE then
        local name = player:get_player_name()
        if pending[name] and fields.quit then
            pending[name].modal_dismissed = true
        end
        return true
    end

    -- Admin panel
    if formname == FORMSPEC_ADMIN then
        local name = player:get_player_name()
        if not has_admin_access(name) then
            return true
        end

        -- Tab switching
        if fields.tabs then
            local tab = tonumber(fields.tabs)
            if tab then
                show_admin_panel(name, tab)
            end
            return true
        end

        -- === Settings tab ===
        if fields.save_settings then
            set_setting("password_template", fields.password_template or "")
            set_setting("countdown_seconds", fields.countdown_seconds or "120")
            set_setting("max_strikes", fields.max_strikes or "3")
            set_setting("reminder_interval", fields.reminder_interval or "10")
            set_setting("admin_email", fields.admin_email or "")
            set_setting("server_title", fields.server_title or "")
            set_setting("verified_privs", fields.verified_privs or "")
            core.chat_send_player(name,
                core.colorize("#55FF55", "[Passgate] Settings saved."))
            show_admin_panel(name, 1)
            return true
        end

        if fields.reset_defaults then
            for key, val in pairs(DEFAULTS) do
                storage:set_string("setting:" .. key, "")
            end
            core.chat_send_player(name,
                core.colorize("#55FF55", "[Passgate] Settings reset to defaults."))
            show_admin_panel(name, 1)
            return true
        end

        if fields.show_inventory_button then
            set_setting("show_inventory_button", fields.show_inventory_button)
            return true
        end

        -- === Players tab ===
        if fields.do_search or fields.key_enter_field == "search_filter" then
            if not admin_state[name] then admin_state[name] = {} end
            admin_state[name].search_filter = fields.search_filter or ""
            admin_state[name].selected_player_idx = nil
            show_admin_panel(name, 2)
            return true
        end

        if fields.clear_search then
            if not admin_state[name] then admin_state[name] = {} end
            admin_state[name].search_filter = ""
            admin_state[name].selected_player_idx = nil
            show_admin_panel(name, 2)
            return true
        end

        if fields.player_table then
            local evt = core.explode_table_event(fields.player_table)
            if evt.type == "CHG" or evt.type == "DCL" then
                -- Subtract 1 for header row; ignore header click
                local idx = evt.row - 1
                if idx >= 1 then
                    if not admin_state[name] then admin_state[name] = {} end
                    admin_state[name].selected_player_idx = idx
                    -- Preserve search filter from the field
                    if fields.search_filter then
                        admin_state[name].search_filter = fields.search_filter
                    end
                    show_admin_panel(name, 2)
                end
            end
            return true
        end

        if fields.verify_player then
            local state = admin_state[name]
            if state and state.player_list and state.selected_player_idx then
                local p = state.player_list[state.selected_player_idx]
                if p then
                    set_verified(p.name)
                    -- Grant privs if online
                    local target = core.get_player_by_name(p.name)
                    if target then
                        core.set_player_privs(p.name, get_verified_privs())
                        core.notify_authentication_modified(p.name)
                        target:set_physics_override({ speed = 1, jump = 1, gravity = 1 })
                        core.close_formspec(p.name, FORMSPEC_GATE)
                        core.chat_send_player(p.name,
                            core.colorize("#55FF55",
                                "You have been verified! Welcome to "
                                .. get_server_title() .. "!"))
                        pending[p.name] = nil
                    end
                    core.chat_send_player(name,
                        core.colorize("#55FF55",
                            "[Passgate] " .. p.name .. " verified."))
                    show_admin_panel(name, 2)
                end
            end
            return true
        end

        if fields.block_player then
            local state = admin_state[name]
            if state and state.player_list and state.selected_player_idx then
                local p = state.player_list[state.selected_player_idx]
                if p then
                    show_block_confirm(name, p.name)
                end
            end
            return true
        end

        if fields.unblock_player then
            local state = admin_state[name]
            if state and state.player_list and state.selected_player_idx then
                local p = state.player_list[state.selected_player_idx]
                if p then
                    unset_blocked(p.name)
                    reset_strikes(p.name)
                    core.chat_send_player(name,
                        core.colorize("#55FF55",
                            "[Passgate] " .. p.name
                            .. " unblocked and strikes reset."))
                    show_admin_panel(name, 2)
                end
            end
            return true
        end

        if fields.reset_strikes then
            local state = admin_state[name]
            if state and state.player_list and state.selected_player_idx then
                local p = state.player_list[state.selected_player_idx]
                if p then
                    reset_strikes(p.name)
                    core.chat_send_player(name,
                        core.colorize("#55FF55",
                            "[Passgate] Strikes reset for " .. p.name .. "."))
                    show_admin_panel(name, 2)
                end
            end
            return true
        end

        if fields.toggle_admin then
            local state = admin_state[name]
            if state and state.player_list and state.selected_player_idx then
                local p = state.player_list[state.selected_player_idx]
                if p then
                    local privs = core.get_player_privs(p.name)
                    if p.is_gate_admin then
                        -- Revoke passgate_admin
                        privs.passgate_admin = nil
                        core.set_player_privs(p.name, privs)
                        core.notify_authentication_modified(p.name)
                        core.chat_send_player(name,
                            core.colorize("#FF5555",
                                "[Passgate] Revoked passgate_admin from "
                                .. p.name .. "."))
                    else
                        -- Grant passgate_admin
                        privs.passgate_admin = true
                        core.set_player_privs(p.name, privs)
                        core.notify_authentication_modified(p.name)
                        core.chat_send_player(name,
                            core.colorize("#55FF55",
                                "[Passgate] Granted passgate_admin to "
                                .. p.name .. "."))
                    end
                    show_admin_panel(name, 2)
                end
            end
            return true
        end

        if fields.refresh_players then
            show_admin_panel(name, 2)
            return true
        end

        -- === Status tab ===
        if fields.refresh_status then
            show_admin_panel(name, 3)
            return true
        end

        return true
    end

    -- Block confirmation dialog
    if formname == FORMSPEC_BLOCK_CONFIRM then
        local name = player:get_player_name()
        if not has_admin_access(name) then
            return true
        end

        if fields.confirm_block then
            local state = admin_state[name]
            local target_name = state and state.block_target
            if target_name then
                local reason = fields.block_reason
                if not reason or reason:trim() == "" then
                    reason = "Manually blocked by " .. name
                end
                set_blocked(target_name, reason)
                local auth_handler = core.get_auth_handler()
                if auth_handler.get_auth(target_name) then
                    auth_handler.delete_auth(target_name)
                    core.notify_authentication_modified(target_name)
                end
                local target = core.get_player_by_name(target_name)
                if target then
                    core.kick_player(target_name, build_ban_message(target_name))
                end
                pending[target_name] = nil
                state.block_target = nil
                core.chat_send_player(name,
                    core.colorize("#FF5555",
                        "[Passgate] " .. target_name .. " blocked. Reason: " .. reason))
                show_admin_panel(name, 2)
            end
            return true
        end

        if fields.cancel_block or fields.quit then
            local state = admin_state[name]
            if state then
                state.block_target = nil
            end
            show_admin_panel(name, 2)
            return true
        end

        return true
    end

    return false
end)

-- ============================================================================
-- Countdown timer (globalstep) — 1-second tick
-- ============================================================================

local tick_accumulator = 0

core.register_globalstep(function(dtime)
    server_clock = server_clock + dtime
    tick_accumulator = tick_accumulator + dtime
    if tick_accumulator < 1 then
        return
    end
    local elapsed = math.floor(tick_accumulator)
    tick_accumulator = tick_accumulator - elapsed

    local to_remove = {}

    for name, state in pairs(pending) do
        state.remaining = state.remaining - elapsed

        if state.remaining <= 0 then
            -- Time's up: kick, strike, purge account
            local player = core.get_player_by_name(name)
            local lname = name:lower()
            local strikes = add_strike(lname)
            local max_strikes = get_setting_int("max_strikes")

            local auth_handler = core.get_auth_handler()
            auth_handler.delete_auth(name)
            core.notify_authentication_modified(name)

            local kick_msg
            if strikes >= max_strikes then
                set_blocked(lname, "Exceeded maximum strikes")
                kick_msg = "Strike " .. strikes .. "/" .. max_strikes
                    .. ". " .. build_ban_message(lname)
            else
                kick_msg = "Strike " .. strikes .. "/" .. max_strikes
                    .. ". You did not change your password in time.\n"
                    .. "You may try again. "
                    .. (max_strikes - strikes) .. " attempt(s) remaining."
            end

            if player then
                core.kick_player(name, kick_msg)
            end

            table.insert(to_remove, name)
            core.log("action", "[dynamic_passgate] Player " .. name
                .. " timed out. Strike " .. strikes .. "/" .. max_strikes)
        else
            local player = core.get_player_by_name(name)
            if player then
                if not state.modal_dismissed then
                    show_gate(player, math.ceil(state.remaining))
                else
                    state.reminder_timer = state.reminder_timer + elapsed
                    local interval = get_setting_int("reminder_interval")
                    if state.reminder_timer >= interval then
                        state.reminder_timer = state.reminder_timer - interval
                        local template = get_setting("password_template")
                        local current_pw = expand_template(template, name)
                        local r = math.ceil(state.remaining)
                        local remaining_str = string.format("%dm%02ds",
                            math.floor(r / 60), r % 60)
                        core.chat_send_player(name,
                            core.colorize("#FF6B6B",
                                "[GATE] " .. remaining_str .. " remaining. ")
                            .. "Open chat (T) and type: "
                            .. core.colorize("#FFFF55",
                                "/password " .. current_pw
                                .. " <your-new-password>"))
                    end
                end
            end
        end
    end

    for _, name in ipairs(to_remove) do
        pending[name] = nil
    end
end)

-- ============================================================================
-- Password change detection via auth handler hook
-- ============================================================================

local function on_password_changed(name)
    local lname = name:lower()

    if is_verified(lname) then
        return
    end

    set_verified(lname)

    core.set_player_privs(name, get_verified_privs())
    core.notify_authentication_modified(name)

    local player = core.get_player_by_name(name)
    if player then
        player:set_physics_override({
            speed = 1,
            jump = 1,
            gravity = 1,
        })

        core.close_formspec(name, FORMSPEC_GATE)

        core.chat_send_player(name,
            core.colorize("#55FF55",
                "Password changed. Welcome to " .. get_server_title() .. "! "
                .. "All privileges granted. Have fun!"))
    end

    pending[name] = nil

    core.log("action", "[dynamic_passgate] Player " .. name
        .. " verified and granted full privileges")
end

core.register_on_mods_loaded(function()
    local auth_handler = core.get_auth_handler()
    local original_set_password = auth_handler.set_password

    auth_handler.set_password = function(name, password)
        local result = original_set_password(name, password)
        on_password_changed(name)
        return result
    end

    core.log("action", "[dynamic_passgate] Hooked auth handler set_password")
end)

-- ============================================================================
-- Clean up on player leave
-- ============================================================================

core.register_on_leaveplayer(function(player, timed_out)
    local name = player:get_player_name()
    pending[name] = nil
    admin_state[name] = nil
end)

-- ============================================================================
-- Server-side /password command (fallback for clients that don't handle it)
-- ============================================================================

core.register_chatcommand("password", {
    params = "<old_password> <new_password>",
    description = "Change your password",
    privs = {},
    func = function(name, param)
        local old_pw, new_pw = param:match("^(%S+)%s+(%S+)$")
        if not old_pw or not new_pw then
            return false, "Usage: /password <old_password> <new_password>"
        end

        local auth_handler = core.get_auth_handler()
        local auth = auth_handler.get_auth(name)
        if not auth then
            return false, "Authentication error. Contact the server admin."
        end

        local old_hash = core.get_password_hash(name, old_pw)
        if old_hash ~= auth.password then
            return false, "Old password is incorrect."
        end

        local new_hash = core.get_password_hash(name, new_pw)
        auth_handler.set_password(name, new_hash)
        core.notify_authentication_modified(name)

        return true, "Password changed successfully."
    end,
})

-- ============================================================================
-- Chat commands
-- ============================================================================

core.register_chatcommand("gate", {
    params = "",
    description = "Open the Dynamic Passgate admin panel",
    privs = {},
    func = function(name, param)
        if not has_admin_access(name) then
            return false, "You don't have permission to use this command."
        end
        show_admin_panel(name, 1)
        return true, "Opening admin panel..."
    end,
})

core.register_chatcommand("gate_verify", {
    params = "<playername>",
    description = "Manually verify a player",
    privs = {},
    func = function(caller, param)
        if not has_admin_access(caller) then
            return false, "You don't have permission to use this command."
        end
        local target = param:trim()
        if target == "" then
            return false, "Usage: /gate_verify <playername>"
        end
        local lname = target:lower()
        set_verified(lname)
        -- Grant privs + unfreeze if online
        local player = core.get_player_by_name(target)
        if player then
            core.set_player_privs(target, get_verified_privs())
            core.notify_authentication_modified(target)
            player:set_physics_override({ speed = 1, jump = 1, gravity = 1 })
            core.close_formspec(target, FORMSPEC_GATE)
            core.chat_send_player(target,
                core.colorize("#55FF55",
                    "You have been verified! Welcome to "
                    .. get_server_title() .. "!"))
            pending[target] = nil
        end
        return true, target .. " has been manually verified."
    end,
})

core.register_chatcommand("gate_block", {
    params = "<playername> [reason]",
    description = "Block a player from joining, with optional reason",
    privs = {},
    func = function(caller, param)
        if not has_admin_access(caller) then
            return false, "You don't have permission to use this command."
        end
        local target, reason = param:match("^(%S+)%s+(.+)$")
        if not target then
            target = param:trim()
            reason = nil
        end
        if target == "" then
            return false, "Usage: /gate_block <playername> [reason]"
        end
        local lname = target:lower()
        set_blocked(lname, reason)
        local auth_handler = core.get_auth_handler()
        if auth_handler.get_auth(target) then
            auth_handler.delete_auth(target)
            core.notify_authentication_modified(target)
        end
        local player = core.get_player_by_name(target)
        if player then
            core.kick_player(target, build_ban_message(lname))
        end
        pending[target] = nil
        local msg = target .. " has been blocked and their account purged."
        if reason then
            msg = msg .. " Reason: " .. reason
        end
        return true, msg
    end,
})

core.register_chatcommand("gate_unblock", {
    params = "<playername>",
    description = "Unblock a player and reset their strikes",
    privs = {},
    func = function(caller, param)
        if not has_admin_access(caller) then
            return false, "You don't have permission to use this command."
        end
        local target = param:trim()
        if target == "" then
            return false, "Usage: /gate_unblock <playername>"
        end
        local lname = target:lower()
        unset_blocked(lname)
        reset_strikes(lname)
        return true, target .. " has been unblocked and strikes reset."
    end,
})

core.register_chatcommand("gate_status", {
    params = "<playername>",
    description = "Check gate status of a player",
    privs = {},
    func = function(caller, param)
        if not has_admin_access(caller) then
            return false, "You don't have permission to use this command."
        end
        local target = param:trim()
        if target == "" then
            return false, "Usage: /gate_status <playername>"
        end
        local lname = target:lower()
        local verified = is_verified(lname)
        local strikes = get_strikes(lname)
        local blocked = is_blocked(lname)
        local max_s = get_setting_int("max_strikes")
        local msg = target .. ": verified=" .. tostring(verified)
            .. ", strikes=" .. strikes .. "/" .. max_s
            .. ", blocked=" .. tostring(blocked)
        if blocked then
            local reason = get_block_reason(lname)
            if reason then
                msg = msg .. ", reason=" .. reason
            end
        end
        return true, msg
    end,
})

-- ============================================================================
-- Inventory button (optional, compatible with sfinv_buttons > sfinv > no-op)
-- ============================================================================

if sfinv_buttons then
    -- Best case: sfinv_buttons is available, register in the "More" tab
    sfinv_buttons.register_button("dynamic_passgate_admin", {
        title = "Gate Admin",
        image = "dynamic_passgate_icon.png",
        tooltip = "Open the Dynamic Passgate admin panel",
        show = function(player)
            if not get_setting_bool("show_inventory_button") then
                return false
            end
            return has_admin_access(player:get_player_name())
        end,
        action = function(player)
            show_admin_panel(player:get_player_name(), 1)
        end,
    })
elseif sfinv then
    -- Fallback: plain sfinv page as an inventory tab
    sfinv.register_page("dynamic_passgate:admin", {
        title = "Gate",
        is_in_nav = function(self, player, context)
            if not get_setting_bool("show_inventory_button") then
                return false
            end
            return has_admin_access(player:get_player_name())
        end,
        get = function(self, player, context)
            return sfinv.make_formspec(player, context,
                "image_button[1.5,1;5,1;dynamic_passgate_icon.png;sfinv_gate_open;Open Gate Admin Panel]"
                .. "label[1.5,2.5;" .. core.colorize("#888888",
                    "Or use /gate in chat") .. "]",
                false)
        end,
        on_player_receive_fields = function(self, player, context, fields)
            if fields.sfinv_gate_open then
                show_admin_panel(player:get_player_name(), 1)
                return true
            end
        end,
    })
else
    -- Vanilla fallback: no sfinv at all, append button to inventory formspec
    local function set_vanilla_inv_button(player)
        local name = player:get_player_name()
        if not get_setting_bool("show_inventory_button") then
            player:set_inventory_formspec("")
            return
        end
        if not has_admin_access(name) then
            player:set_inventory_formspec("")
            return
        end
        -- Append a small "Gate Admin" button to the default inventory form
        -- Using formspec_version[6] with absolute positioning
        local fs = "formspec_version[6]"
            .. "size[10.4,11]"
            .. "list[current_player;main;0.4,5.5;8,4;]"
            .. "list[current_player;craft;1.75,0.5;3,3;]"
            .. "list[current_player;craftpreview;6.1,1.5;1,1;]"
            .. "image[5.05,1.5;1,1;gui_furnace_arrow_bg.png^[transformR270]"
            .. "image_button[0.4,10;4,0.7;dynamic_passgate_icon.png;vanilla_gate_open;Gate Admin]"
        player:set_inventory_formspec(fs)
    end

    -- Set the inventory formspec on join for admins
    core.register_on_joinplayer(function(player, last_login)
        -- Delay slightly so other on_joinplayer handlers finish first
        core.after(0.5, function()
            local name = player:get_player_name()
            -- Check player is still online
            if core.get_player_by_name(name) then
                set_vanilla_inv_button(player)
            end
        end)
    end)

    -- Handle the button click
    core.register_on_player_receive_fields(function(player, formname, fields)
        if fields.vanilla_gate_open then
            local name = player:get_player_name()
            if has_admin_access(name) then
                show_admin_panel(name, 1)
            end
            return true
        end
        return false
    end)
end

-- ============================================================================
-- Startup
-- ============================================================================

core.log("action", "[dynamic_passgate] v" .. MOD_VERSION .. " loaded. "
    .. "Template: " .. get_setting("password_template"))
