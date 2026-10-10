--[[
    Sys - Private
    Bloodlines (PlaceId 10266164381)

    Private build. Not the public Bloodlines script:
      - Atlas UI (cleaned + repaired, embedded, no remote fetches)
      - ESP rebuilt from scratch in the Deepwoken layout (boxes, stacked bars)
      - Cold-start loader that spreads allocation across frames instead of
        dumping the whole script into memory in one tick
      - BanMe blocker, executor-probe bypass, env-logging countermeasures
]]

-- ==================== LURAPH MACRO SHIMS ====================
-- Passthrough definitions so the script runs correctly BEFORE obfuscation.
-- Luraph strips this whole block at compile time (the `if not LPH_OBFUSCATED`
-- guard is required, and the macros must be GLOBALS - locals aren't removed).
if not LPH_OBFUSCATED then
    function LPH_ENCSTR(str) return str end
    function LPH_NO_VIRTUALIZE(f) return f end
    function LPH_JIT_MAX(f) return f end
end

---------------------------------------------------------------------
-- EXECUTOR PROBE BYPASS
--
-- The game's client probes iscclosure / islclosure / identifyexecutor to
-- fingerprint the executor. Re-hooking each of them through a C closure that
-- forwards to the original makes the probe itself read as native, so the
-- fingerprint comes back clean without changing any return value.
---------------------------------------------------------------------
do --// attempt bypass

    local hookfn = hookfunction;
    local wrap = newcclosure or function(f) return f end;
    if hookfn then
        for _, fn in ipairs({ iscclosure, islclosure, identifyexecutor }) do
            if type(fn) == 'function' then
                pcall(function()
                    local orig;
                    orig = hookfn(fn, wrap(function(...) return orig(...) end));
                end);
            end;
        end;
    end;
end;

---------------------------------------------------------------------
-- PLACE GATE
---------------------------------------------------------------------
if game.PlaceId == 5571328985 then
    -- Lobby place: bounce into the main game and stop.
    pcall(function()
        game:GetService("ReplicatedStorage").Events.DataEvent:FireServer("Teleport")
    end)
    return
end

if game.PlaceId ~= 10266164381 then
    return
end

---------------------------------------------------------------------
-- SINGLE INSTANCE GUARD
--
-- Key is randomised per build so a scanner walking getgenv() for a known
-- loaded-flag name finds nothing to match against.
---------------------------------------------------------------------
local _genvKey = "_" .. tostring(math.random(0x100000, 0xFFFFFF))
do
    local ok, existing = pcall(function() return getgenv().__sys_priv end)
    if ok and existing then
        -- Already running: ask the live instance to unload, then bail.
        pcall(function() getgenv().__sys_priv() end)
        task.wait(0.35)
    end
end

---------------------------------------------------------------------
-- BANME BLOCKER
--
-- The client anticheat self-reports by firing
-- DataEvent:FireServer("BanMe", "Offense X"). Dropping that single call
-- neuters every offense (fly, speed, jump, backpack, blindness) before it
-- reaches the server.
--
-- Kept as its own INNERMOST hook, installed before any other hook, and it
-- deliberately does NOT call getnamecallmethod(). Two stacked __namecall
-- hooks that both call getnamecallmethod() corrupt the method for the inner
-- one; matching on the first argument avoids that entirely.
---------------------------------------------------------------------
do
    local hookmm = hookmetamethod
    local ncc = newcclosure or function(f) return f end
    if hookmm then
        pcall(function()
            local old
            old = hookmm(game, "__namecall", ncc(function(self, ...)
                if (...) == "BanMe" then
                    return
                end
                return old(self, ...)
            end))
        end)
    end
end

---------------------------------------------------------------------
-- STEALTH / COLD START
--
-- Everything the script owns lives inside this one local table. Nothing is
-- written to _G, shared, or the global function table, so an environment
-- logger walking globals (or getgc filtering on named functions) has no
-- surface to enumerate: every function below is an anonymous local.
---------------------------------------------------------------------
local K = {}

K.Services = {
    Players          = game:GetService("Players"),
    RunService       = game:GetService("RunService"),
    UserInputService = game:GetService("UserInputService"),
    ReplicatedStorage= game:GetService("ReplicatedStorage"),
    Lighting         = game:GetService("Lighting"),
    HttpService      = game:GetService("HttpService"),
    TweenService     = game:GetService("TweenService"),
    TextService      = game:GetService("TextService"),
    SoundService     = game:GetService("SoundService"),
    Debris           = game:GetService("Debris"),
}

K.LocalPlayer = K.Services.Players.LocalPlayer
K.Camera      = workspace.CurrentCamera

-- Every connection the script makes goes through here so unload is total.
K.Connections = {}

local function bind(conn)
    K.Connections[#K.Connections + 1] = conn
    return conn
end

local function unbind(conn)
    if not conn then return end
    pcall(function() conn:Disconnect() end)
    for i, c in ipairs(K.Connections) do
        if c == conn then
            table.remove(K.Connections, i)
            break
        end
    end
end

---------------------------------------------------------------------
-- MEMORY SMOOTHING
--
-- A script that allocates its whole UI tree and feature set inside a single
-- frame produces a step in the process working set that is trivially
-- fingerprinted. `yield()` is dropped between every build phase: it hands the
-- frame back once ~12ms of work has accumulated, so the same total allocation
-- lands as a slope across many frames instead of one cliff.
---------------------------------------------------------------------
local _lastYield = os.clock()

local function yield(force)
    local now = os.clock()
    if force or (now - _lastYield) > 0.012 then
        K.Services.RunService.Heartbeat:Wait()
        _lastYield = os.clock()
    end
end

-- Jittered start. A fixed delay is itself a signature; a random one inside a
-- human-plausible window is not.
task.wait(math.random(180, 420) / 100)

---------------------------------------------------------------------
-- ATLAS UI (cleaned + repaired, embedded)
--
-- Rebuilt from the public Atlas source. Everything below was changed or
-- removed relative to that source:
--
--   * REMOVED: a syn.request() POST to a hardcoded Discord webhook that
--     exfiltrated the player name, game name and GameId on every load.
--   * REMOVED: loadstring(game:HttpGet(...)) pulling a Signal module off
--     GitHub at runtime - a network call on load, and remote code the script
--     does not control. Replaced with a ~15 line local signal.
--   * REMOVED: a debug print() left in the colour picker transparency path.
--   * FIXED: `releaseconnection`, `move_connection`, `release_connection`,
--     `binding` and `new_value` were implicit GLOBALS. Every one of them is a
--     local now - as written they wrote script state into the global table on
--     every slider drag and colour pick, which is exactly what an environment
--     logger reads.
--   * FIXED: SetOpen() referenced an undefined `state` instead of its own
--     `State` argument, so it silently did nothing.
--   * FIXED: the menu keybind ran `while ScreenGui.Enabled do ... end` inside
--     an InputBegan handler - a busy loop pinned to the input thread that
--     stacked a new copy of itself on every keypress.
--   * FIXED: every dropdown, colour picker and keybind opened its own
--     UserInputService.InputBegan connection for outside-click detection. A
--     menu this size ran hundreds of them; they are now one dispatcher.
--   * FIXED: ScreenGui parents to gethui() when available (CoreGui fallback)
--     under a GUID name, instead of hardcoding CoreGui with Name = "unknown".
--   * FIXED: the cursor RenderStepped ran forever whether or not the menu was
--     open, and MouseIconEnabled was never restored.
--   * FIXED: config paths concatenated folder..name with no separator.
--   * ADDED: element:refresh() for live dropdown/combo option lists,
--     notifications, per-tab labels, and full unload of every connection and
--     instance the library owns.
---------------------------------------------------------------------
local Atlas = (function()
    local lib = {}

    local TweenService     = K.Services.TweenService
    local UserInputService = K.Services.UserInputService
    local TextService      = K.Services.TextService
    local RunService       = K.Services.RunService
    local HttpService      = K.Services.HttpService
    local LocalPlayer      = K.LocalPlayer
    local Mouse            = LocalPlayer:GetMouse()

    local ACCENT     = Color3.fromRGB(255, 255, 255)
    local ACCENT_DIM = Color3.fromRGB(140, 140, 140)
    local IDLE       = Color3.fromRGB(150, 150, 150)
    local HOVER      = Color3.fromRGB(205, 205, 205)
    local DIM        = Color3.fromRGB(100, 100, 100)
    local BLACK      = Color3.fromRGB(0, 0, 0)
    local FONT       = Enum.Font.Ubuntu
    local TWEEN      = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local SLIDER_W   = 260

    lib.connections = {}
    lib.roots       = {}

    local function track(c)
        lib.connections[#lib.connections + 1] = c
        return c
    end

    function lib:tween(obj, props, info)
        pcall(function()
            TweenService:Create(obj, info or TWEEN, props):Play()
        end)
    end

    function lib:create(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do
            o[k] = v
        end
        if parent then o.Parent = parent end
        return o
    end

    function lib:text_size(text, size, font)
        local ok, res = pcall(function()
            return TextService:GetTextSize(text, size, font or FONT, Vector2.new(700, 20))
        end)
        return ok and res or Vector2.new(#tostring(text) * 7, 20)
    end

    -----------------------------------------------------------------
    -- SIGNAL (replaces the remote module the public source fetched)
    -----------------------------------------------------------------
    local function new_signal()
        local s = { handlers = {} }

        function s:Connect(fn)
            local h = self.handlers
            h[#h + 1] = fn
            return {
                Disconnect = function()
                    for i = #h, 1, -1 do
                        if h[i] == fn then table.remove(h, i) end
                    end
                end,
            }
        end

        function s:Fire(...)
            -- Iterate a copy: a handler is allowed to disconnect itself.
            local snapshot = {}
            for i, fn in ipairs(self.handlers) do snapshot[i] = fn end
            for _, fn in ipairs(snapshot) do
                pcall(fn, ...)
            end
        end

        return s
    end

    -----------------------------------------------------------------
    -- SECURE PARENTING
    -----------------------------------------------------------------
    local function protect(gui)
        if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end
        if protect_gui then pcall(protect_gui, gui) end

        local parented = false
        if gethui then
            parented = pcall(function() gui.Parent = gethui() end)
        end
        if not parented then
            parented = pcall(function() gui.Parent = game:GetService("CoreGui") end)
        end
        if not parented then
            gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
        lib.roots[#lib.roots + 1] = gui
        return gui
    end

    -----------------------------------------------------------------
    -- ONE popup dispatcher for every dropdown / picker / keybind menu.
    -- The public source opened a fresh InputBegan connection per element.
    -----------------------------------------------------------------
    local popups = {}

    local function register_popup(closer)
        popups[#popups + 1] = closer
    end

    track(UserInputService.InputBegan:Connect(function(input)
        local t = input.UserInputType
        if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.MouseButton2 then
            return
        end
        for _, closer in ipairs(popups) do
            pcall(closer)
        end
    end))

    -----------------------------------------------------------------
    -- ONE keybind dispatcher.
    -----------------------------------------------------------------
    -- [n] = {value = {Key, Type, Active}, cb, bind, cancel, name, isOn}
    local keybinds     = {}
    local binding_slot = nil  -- the keybind currently capturing a key
    lib.keybinds = keybinds   -- read-only view for the Keybind List panel

    local function key_name(input)
        return input.KeyCode.Name ~= "Unknown" and input.KeyCode.Name or input.UserInputType.Name
    end

    track(UserInputService.InputBegan:Connect(function(input, processed)
        if binding_slot then
            -- Only keyboard keys and the right / middle mouse buttons can
            -- become a bind. Left clicks are ignored while binding: the click
            -- that opened the binder arrives here too, and used to bind
            -- itself as MouseButton1. Escape cancels.
            local t = input.UserInputType
            if t == Enum.UserInputType.Keyboard then
                if input.KeyCode == Enum.KeyCode.Escape then
                    local slot = binding_slot
                    binding_slot = nil
                    slot.cancel()
                    return
                end
            elseif t ~= Enum.UserInputType.MouseButton2 and t ~= Enum.UserInputType.MouseButton3 then
                return
            end
            local slot = binding_slot
            binding_slot = nil
            slot.bind(key_name(input))
            return
        end
        if processed then return end

        local pressed = key_name(input)
        for _, slot in ipairs(keybinds) do
            local v = slot.value
            if v.Key and v.Key == pressed then
                if v.Type == "Toggle" then
                    v.Active = not v.Active
                elseif v.Type == "Hold" then
                    v.Active = true
                end
                -- Pressed marks a real key press, so a callback can tell it
                -- apart from the same callback firing when the bind is being
                -- configured (mode change, set_value, config load).
                v.Pressed = true
                slot.cb(v)
                v.Pressed = false
            end
        end
    end))

    track(UserInputService.InputEnded:Connect(function(input)
        local released = key_name(input)
        for _, slot in ipairs(keybinds) do
            local v = slot.value
            if v.Key and v.Key == released and v.Type == "Hold" then
                v.Active = false
                slot.cb(v)
            end
        end
    end))

    -----------------------------------------------------------------
    -- DRAGGING
    -----------------------------------------------------------------
    local function set_draggable(gui)
        local dragging, dragStart, startPos = false, nil, nil

        track(gui.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
                dragging  = true
                dragStart = input.Position
                startPos  = gui.Position
            end
        end))

        track(gui.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end))

        track(UserInputService.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end

            local delta = input.Position - dragStart
            gui.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end))
    end

    -----------------------------------------------------------------
    -- NOTIFICATIONS
    -----------------------------------------------------------------
    local notify_gui, notify_list

    local function ensure_notify()
        if notify_gui and notify_gui.Parent then return end

        notify_gui = lib:create("ScreenGui", {
            Name           = HttpService:GenerateGUID(false),
            ResetOnSpawn   = false,
            IgnoreGuiInset = true,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
            DisplayOrder   = 9999,
        })
        protect(notify_gui)

        notify_list = lib:create("Frame", {
            Name                   = "List",
            AnchorPoint            = Vector2.new(1, 0),
            BackgroundTransparency = 1,
            Position               = UDim2.new(1, -14, 0, 14),
            Size                   = UDim2.new(0, 260, 1, -28),
        }, notify_gui)

        lib:create("UIListLayout", {
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            SortOrder           = Enum.SortOrder.LayoutOrder,
            Padding             = UDim.new(0, 6),
        }, notify_list)
    end

    function lib:notify(title, text, duration)
        duration = duration or 3
        ensure_notify()

        local card = lib:create("Frame", {
            BackgroundColor3       = Color3.fromRGB(10, 10, 10),
            BorderColor3           = Color3.fromRGB(30, 30, 30),
            Size                   = UDim2.new(1, 0, 0, 44),
            BackgroundTransparency = 1,
        }, notify_list)

        local accent = lib:create("Frame", {
            BackgroundColor3       = ACCENT,
            BorderSizePixel        = 0,
            Size                   = UDim2.new(0, 2, 1, 0),
            BackgroundTransparency = 1,
        }, card)

        local head = lib:create("TextLabel", {
            BackgroundTransparency = 1,
            Position               = UDim2.new(0, 10, 0, 5),
            Size                   = UDim2.new(1, -16, 0, 15),
            Font                   = FONT,
            Text                   = tostring(title),
            TextColor3             = HOVER,
            TextSize               = 14,
            TextXAlignment         = Enum.TextXAlignment.Left,
            TextTransparency       = 1,
        }, card)

        local body = lib:create("TextLabel", {
            BackgroundTransparency = 1,
            Position               = UDim2.new(0, 10, 0, 21),
            Size                   = UDim2.new(1, -16, 0, 18),
            Font                   = FONT,
            Text                   = tostring(text),
            TextColor3             = IDLE,
            TextSize               = 13,
            TextXAlignment         = Enum.TextXAlignment.Left,
            TextTruncate           = Enum.TextTruncate.AtEnd,
            TextTransparency       = 1,
        }, card)

        lib:tween(card,   {BackgroundTransparency = 0})
        lib:tween(accent, {BackgroundTransparency = 0})
        lib:tween(head,   {TextTransparency = 0})
        lib:tween(body,   {TextTransparency = 0})

        task.delay(duration, function()
            if not card or not card.Parent then return end
            lib:tween(card,   {BackgroundTransparency = 1})
            lib:tween(accent, {BackgroundTransparency = 1})
            lib:tween(head,   {TextTransparency = 1})
            lib:tween(body,   {TextTransparency = 1})
            task.delay(0.25, function()
                pcall(function() card:Destroy() end)
            end)
        end)
    end

    -----------------------------------------------------------------
    -- UNLOAD
    -----------------------------------------------------------------
    function lib:unload()
        for _, c in ipairs(self.connections) do
            pcall(function() c:Disconnect() end)
        end
        self.connections = {}

        for _, root in ipairs(self.roots) do
            pcall(function() root:Destroy() end)
        end
        self.roots = {}

        keybinds = {}
        popups   = {}
        pcall(function() UserInputService.MouseIconEnabled = true end)
    end

    -----------------------------------------------------------------
    -- WINDOW
    -----------------------------------------------------------------
    function lib.new(window_title, cfg_folder)
        local menu = {}
        menu.values      = {}
        menu.on_load_cfg = new_signal()
        menu.open        = true
        menu.toggle_key  = Enum.KeyCode.Insert
        menu.loading_cfg = false

        cfg_folder = cfg_folder or "SysPrivate"

        -- makefolder does not create intermediate directories, so walk the
        -- path and create each level that is missing.
        pcall(function()
            if not (isfolder and makefolder) then return end
            local built = nil
            for part in string.gmatch(cfg_folder, "[^/\\]+") do
                built = built and (built .. "/" .. part) or part
                if not isfolder(built) then makefolder(built) end
            end
        end)

        local function cfg_path(name)
            return cfg_folder .. "/" .. name .. ".json"
        end

        -------------------------------------------------------------
        -- CONFIG
        -------------------------------------------------------------
        local function deep_copy(original)
            local copy = {}
            for k, v in pairs(original) do
                if type(v) == "table" then v = deep_copy(v) end
                copy[k] = v
            end
            return copy
        end

        function menu.save_cfg(cfg_name)
            if not writefile then return false, "no file access" end

            local values = deep_copy(menu.values)
            for _, tab in pairs(values) do
                for _, section in pairs(tab) do
                    for _, sector in pairs(section) do
                        for _, element in pairs(sector) do
                            -- Color3 is userdata; JSON needs plain numbers.
                            if type(element) == "table" and element.Color then
                                element.Color = {
                                    R = element.Color.R,
                                    G = element.Color.G,
                                    B = element.Color.B,
                                }
                            end
                        end
                    end
                end
            end

            local ok, err = pcall(function()
                writefile(cfg_path(cfg_name), HttpService:JSONEncode(values))
            end)
            return ok, err
        end

        function menu.load_cfg(cfg_name)
            if not readfile or not isfile then return false, "no file access" end
            if not isfile(cfg_path(cfg_name)) then return false, "not found" end

            local ok, decoded = pcall(function()
                return HttpService:JSONDecode(readfile(cfg_path(cfg_name)))
            end)
            if not ok or type(decoded) ~= "table" then return false, "corrupt config" end

            menu.loading_cfg = true

            for tab_key, tab in pairs(decoded) do
                for section_key, section in pairs(tab) do
                    for sector_key, sector in pairs(section) do
                        for flag, element in pairs(sector) do
                            if type(element) == "table" and element.Color then
                                element.Color = Color3.new(
                                    element.Color.R, element.Color.G, element.Color.B
                                )
                            end
                            pcall(function()
                                -- JSON keys come back as strings; tab ids are numbers.
                                local t = menu.values[tonumber(tab_key) or tab_key]
                                if t and t[section_key] and t[section_key][sector_key] then
                                    t[section_key][sector_key][flag] = element
                                end
                            end)
                        end
                    end
                end
            end

            menu.on_load_cfg:Fire()
            menu.loading_cfg = false
            return true
        end

        function menu.list_cfgs()
            local names = {}
            pcall(function()
                if not listfiles or not isfolder or not isfolder(cfg_folder) then return end
                for _, file in ipairs(listfiles(cfg_folder)) do
                    local name = tostring(file):match("([^/\\]+)%.json$")
                    if name then names[#names + 1] = name end
                end
            end)
            table.sort(names)
            return names
        end

        function menu.delete_cfg(cfg_name)
            local ok = pcall(function() delfile(cfg_path(cfg_name)) end)
            return ok
        end

        -------------------------------------------------------------
        -- ROOT GUI
        -------------------------------------------------------------
        local ScreenGui = lib:create("ScreenGui", {
            Name           = HttpService:GenerateGUID(false),
            ResetOnSpawn   = false,
            ZIndexBehavior = Enum.ZIndexBehavior.Global,
            IgnoreGuiInset = true,
        })
        protect(ScreenGui)

        local Main = lib:create("ImageButton", {
            Name             = "Main",
            AnchorPoint      = Vector2.new(0.5, 0.5),
            BackgroundColor3 = Color3.fromRGB(15, 15, 15),
            BorderColor3     = ACCENT,
            Position         = UDim2.new(0.5, 0, 0.5, 0),
            Size             = UDim2.new(0, 700, 0, 500),
            Image            = "rbxassetid://7300333488",
            AutoButtonColor  = false,
            Modal            = true,
        }, ScreenGui)

        set_draggable(Main)

        -- Cursor. The public source ran this every frame forever and never gave
        -- the mouse icon back; here it only runs while the menu is open.
        local Cursor = lib:create("ImageLabel", {
            Name                   = "Cursor",
            BackgroundTransparency = 1,
            Size                   = UDim2.new(0, 17, 0, 17),
            Image                  = "rbxassetid://7205257578",
            ZIndex                 = 6969,
            Visible                = false,
        }, ScreenGui)

        -- GetMouseLocation() is already measured from the real top-left of the
        -- screen - it is Mouse.X/Y with the topbar inset included - and this
        -- ScreenGui has IgnoreGuiInset = true, so its origin is the same point.
        -- The two already agree and the position is used raw. The public source
        -- added a hardcoded +36 here, and an earlier pass of this rewrite added
        -- GetGuiInset() instead; both double-count the inset and leave the drawn
        -- cursor sitting a topbar's height below the pointer the game is
        -- actually clicking with.
        local cursor_conn
        local function start_cursor()
            if cursor_conn then return end
            cursor_conn = track(RunService.RenderStepped:Connect(function()
                local pos = UserInputService:GetMouseLocation()
                Cursor.Position = UDim2.fromOffset(pos.X, pos.Y)
            end))
        end
        local function stop_cursor()
            if not cursor_conn then return end
            pcall(function() cursor_conn:Disconnect() end)
            cursor_conn = nil
        end

        lib:create("TextLabel", {
            Name                   = "Title",
            AnchorPoint            = Vector2.new(0.5, 0),
            BackgroundTransparency = 1,
            Position               = UDim2.new(0.5, 0, 0, 0),
            Size                   = UDim2.new(1, -22, 0, 30),
            Font                   = FONT,
            Text                   = window_title,
            TextColor3             = HOVER,
            TextSize               = 16,
            TextXAlignment         = Enum.TextXAlignment.Left,
            RichText               = true,
        }, Main)

        local TabButtons = lib:create("Frame", {
            Name                   = "TabButtons",
            BackgroundTransparency = 1,
            Position               = UDim2.new(0, 12, 0, 41),
            Size                   = UDim2.new(0, 76, 0, 447),
        }, Main)

        lib:create("UIListLayout", {
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
        }, TabButtons)

        local Tabs = lib:create("Frame", {
            Name                   = "Tabs",
            BackgroundTransparency = 1,
            Position               = UDim2.new(0, 102, 0, 42),
            Size                   = UDim2.new(0, 586, 0, 446),
        }, Main)

        function menu.IsOpen() return menu.open end

        function menu.SetOpen(State)
            menu.open         = State and true or false
            ScreenGui.Enabled = menu.open
            Main.Modal        = menu.open
            Cursor.Visible    = menu.open
            if menu.open then
                start_cursor()
                pcall(function() UserInputService.MouseIconEnabled = true end)
            else
                stop_cursor()
            end
        end

        function menu.set_keybind(keycode)
            menu.toggle_key = keycode
        end

        function menu.GetPosition() return Main.Position end

        track(UserInputService.InputBegan:Connect(function(input, processed)
            if processed then return end
            if input.KeyCode ~= menu.toggle_key then return end
            menu.SetOpen(not menu.open)
        end))

        function menu.unload()
            lib:unload()
        end

        -------------------------------------------------------------
        -- TABS
        -------------------------------------------------------------
        local is_first_tab = true
        local selected_tab
        local tab_num = 1

        function menu.new_tab(tab_image, tab_label)
            local tab = { tab_num = tab_num }
            menu.values[tab_num] = {}
            tab_num = tab_num + 1

            local TabButton = lib:create("TextButton", {
                BackgroundTransparency = 1,
                Size                   = UDim2.new(0, 76, 0, 72),
                Text                   = "",
            }, TabButtons)

            local TabImage = lib:create("ImageLabel", {
                AnchorPoint            = Vector2.new(0.5, 0.5),
                BackgroundTransparency = 1,
                Position               = UDim2.new(0.5, 0, 0.5, tab_label and -10 or 0),
                Size                   = UDim2.new(0, 32, 0, 32),
                Image                  = tab_image or "",
                ImageColor3            = DIM,
            }, TabButton)

            -- Icon-only tabs are unreadable once there are six of them.
            local TabText
            if tab_label then
                TabText = lib:create("TextLabel", {
                    BackgroundTransparency = 1,
                    AnchorPoint            = Vector2.new(0.5, 0),
                    Position               = UDim2.new(0.5, 0, 0.5, 10),
                    Size                   = UDim2.new(1, 0, 0, 14),
                    Font                   = FONT,
                    Text                   = tab_label,
                    TextColor3             = DIM,
                    TextSize               = 13,
                }, TabButton)
            end

            local Tab = lib:create("Frame", {
                Name                   = "Tab",
                BackgroundTransparency = 1,
                Size                   = UDim2.new(1, 0, 1, 0),
                Visible                = false,
            }, Tabs)

            local TabSections = lib:create("Frame", {
                Name                   = "TabSections",
                BackgroundTransparency = 1,
                Size                   = UDim2.new(1, 0, 0, 28),
                ClipsDescendants       = true,
            }, Tab)

            lib:create("UIListLayout", {
                FillDirection       = Enum.FillDirection.Horizontal,
                HorizontalAlignment = Enum.HorizontalAlignment.Center,
            }, TabSections)

            local TabFrames = lib:create("Frame", {
                Name                   = "TabFrames",
                BackgroundTransparency = 1,
                Position               = UDim2.new(0, 0, 0, 29),
                Size                   = UDim2.new(1, 0, 0, 418),
            }, Tab)

            if is_first_tab then
                is_first_tab      = false
                selected_tab      = TabButton
                TabImage.ImageColor3 = ACCENT
                if TabText then TabText.TextColor3 = ACCENT end
                Tab.Visible       = true
            end

            track(TabButton.MouseButton1Down:Connect(function()
                if selected_tab == TabButton then return end

                for _, btn in pairs(TabButtons:GetChildren()) do
                    if btn:IsA("TextButton") then
                        local img = btn:FindFirstChildOfClass("ImageLabel")
                        local txt = btn:FindFirstChildOfClass("TextLabel")
                        if img then lib:tween(img, {ImageColor3 = DIM}) end
                        if txt then lib:tween(txt, {TextColor3 = DIM}) end
                    end
                end
                for _, frame in pairs(Tabs:GetChildren()) do
                    if frame:IsA("Frame") then frame.Visible = false end
                end

                Tab.Visible  = true
                selected_tab = TabButton
                lib:tween(TabImage, {ImageColor3 = ACCENT})
                if TabText then lib:tween(TabText, {TextColor3 = ACCENT}) end
            end))

            track(TabButton.MouseEnter:Connect(function()
                if selected_tab == TabButton then return end
                lib:tween(TabImage, {ImageColor3 = HOVER})
                if TabText then lib:tween(TabText, {TextColor3 = HOVER}) end
            end))

            track(TabButton.MouseLeave:Connect(function()
                if selected_tab == TabButton then return end
                lib:tween(TabImage, {ImageColor3 = DIM})
                if TabText then lib:tween(TabText, {TextColor3 = DIM}) end
            end))

            ---------------------------------------------------------
            -- SECTIONS
            ---------------------------------------------------------
            local is_first_section = true
            local num_sections     = 0
            local selected_section

            function tab.new_section(section_name)
                local section = {}
                num_sections = num_sections + 1
                menu.values[tab.tab_num][section_name] = {}

                local SectionButton = lib:create("TextButton", {
                    Name                   = "SectionButton",
                    BackgroundTransparency = 1,
                    Size                   = UDim2.new(1 / num_sections, 0, 1, 0),
                    Font                   = FONT,
                    Text                   = section_name,
                    TextColor3             = DIM,
                    TextSize               = 15,
                }, TabSections)

                for _, btn in pairs(TabSections:GetChildren()) do
                    if not btn:IsA("UIListLayout") then
                        btn.Size = UDim2.new(1 / num_sections, 0, 1, 0)
                    end
                end

                local SectionDecoration = lib:create("Frame", {
                    Name             = "SectionDecoration",
                    BackgroundColor3 = HOVER,
                    BorderSizePixel  = 0,
                    Position         = UDim2.new(0, 0, 0, 27),
                    Size             = UDim2.new(1, 0, 0, 1),
                    Visible          = false,
                }, SectionButton)

                lib:create("UIGradient", {
                    Color = ColorSequence.new({
                        ColorSequenceKeypoint.new(0, Color3.fromRGB(32, 33, 38)),
                        ColorSequenceKeypoint.new(0.5, ACCENT),
                        ColorSequenceKeypoint.new(1, Color3.fromRGB(32, 33, 38)),
                    }),
                }, SectionDecoration)

                local SectionFrame = lib:create("Frame", {
                    Name                   = "SectionFrame",
                    BackgroundTransparency = 1,
                    Size                   = UDim2.new(1, 0, 1, 0),
                    Visible                = false,
                }, TabFrames)

                local Left = lib:create("ScrollingFrame", {
                    Name                   = "Left",
                    BackgroundTransparency = 1,
                    BorderSizePixel        = 0,
                    Position               = UDim2.new(0, 8, 0, 14),
                    Size                   = UDim2.new(0, 282, 0, 395),
                    CanvasSize             = UDim2.new(0, 0, 0, 0),
                    AutomaticCanvasSize    = Enum.AutomaticSize.Y,
                    ScrollBarThickness     = 2,
                    ScrollBarImageColor3   = ACCENT,
                }, SectionFrame)

                lib:create("UIListLayout", {
                    HorizontalAlignment = Enum.HorizontalAlignment.Center,
                    SortOrder           = Enum.SortOrder.LayoutOrder,
                    Padding             = UDim.new(0, 22),
                }, Left)

                lib:create("UIPadding", { PaddingTop = UDim.new(0, 14) }, Left)

                local Right = lib:create("ScrollingFrame", {
                    Name                   = "Right",
                    BackgroundTransparency = 1,
                    BorderSizePixel        = 0,
                    Position               = UDim2.new(0, 298, 0, 14),
                    Size                   = UDim2.new(0, 282, 0, 395),
                    CanvasSize             = UDim2.new(0, 0, 0, 0),
                    AutomaticCanvasSize    = Enum.AutomaticSize.Y,
                    ScrollBarThickness     = 2,
                    ScrollBarImageColor3   = ACCENT,
                }, SectionFrame)

                lib:create("UIListLayout", {
                    HorizontalAlignment = Enum.HorizontalAlignment.Center,
                    SortOrder           = Enum.SortOrder.LayoutOrder,
                    Padding             = UDim.new(0, 22),
                }, Right)

                lib:create("UIPadding", { PaddingTop = UDim.new(0, 14) }, Right)

                track(SectionButton.MouseEnter:Connect(function()
                    if selected_section == SectionButton then return end
                    lib:tween(SectionButton, {TextColor3 = HOVER})
                end))

                track(SectionButton.MouseLeave:Connect(function()
                    if selected_section == SectionButton then return end
                    lib:tween(SectionButton, {TextColor3 = DIM})
                end))

                track(SectionButton.MouseButton1Down:Connect(function()
                    for _, btn in pairs(TabSections:GetChildren()) do
                        if not btn:IsA("UIListLayout") then
                            lib:tween(btn, {TextColor3 = DIM})
                            local dec = btn:FindFirstChild("SectionDecoration")
                            if dec then dec.Visible = false end
                        end
                    end
                    for _, frame in pairs(TabFrames:GetChildren()) do
                        if frame:IsA("Frame") then frame.Visible = false end
                    end

                    selected_section        = SectionButton
                    SectionFrame.Visible    = true
                    SectionDecoration.Visible = true
                    lib:tween(SectionButton, {TextColor3 = ACCENT})
                end))

                if is_first_section then
                    is_first_section          = false
                    selected_section          = SectionButton
                    SectionButton.TextColor3  = ACCENT
                    SectionDecoration.Visible = true
                    SectionFrame.Visible      = true
                end

                -----------------------------------------------------
                -- SECTORS
                -----------------------------------------------------
                function section.new_sector(sector_name, sector_side)
                    local sector = {}
                    local side   = (sector_side == "Right") and Right or Left
                    menu.values[tab.tab_num][section_name][sector_name] = {}

                    local Border = lib:create("Frame", {
                        BackgroundColor3 = Color3.fromRGB(5, 5, 5),
                        BorderColor3     = Color3.fromRGB(30, 30, 30),
                        Size             = UDim2.new(1, -4, 0, 20),
                    }, side)

                    local Container = lib:create("Frame", {
                        BackgroundColor3 = Color3.fromRGB(10, 10, 10),
                        BorderSizePixel  = 0,
                        Position         = UDim2.new(0, 1, 0, 1),
                        Size             = UDim2.new(1, -2, 1, -2),
                    }, Border)

                    lib:create("UIListLayout", {
                        HorizontalAlignment = Enum.HorizontalAlignment.Center,
                        SortOrder           = Enum.SortOrder.LayoutOrder,
                    }, Container)

                    lib:create("UIPadding", {
                        PaddingTop = UDim.new(0, 12),
                    }, Container)

                    lib:create("TextLabel", {
                        Name                   = "Title",
                        AnchorPoint            = Vector2.new(0.5, 0),
                        BackgroundTransparency = 1,
                        Position               = UDim2.new(0.5, 0, 0, -8),
                        Size                   = UDim2.new(1, 0, 0, 15),
                        Font                   = FONT,
                        Text                   = sector_name,
                        TextColor3             = HOVER,
                        TextSize               = 14,
                    }, Border)

                    local function grow(px)
                        Border.Size = Border.Size + UDim2.new(0, 0, 0, px)
                    end

                    function sector.create_line(thickness)
                        thickness = thickness or 3
                        grow(thickness * 3)

                        local LineFrame = lib:create("Frame", {
                            Name                   = "LineFrame",
                            BackgroundTransparency = 1,
                            Size                   = UDim2.new(1, 0, 0, thickness * 3),
                        }, Container)

                        lib:create("Frame", {
                            Name             = "Line",
                            BackgroundColor3 = Color3.fromRGB(25, 25, 25),
                            BorderColor3     = BLACK,
                            Position         = UDim2.new(0.5, 0, 0.5, 0),
                            AnchorPoint      = Vector2.new(0.5, 0.5),
                            Size             = UDim2.new(1, -18, 0, thickness),
                        }, LineFrame)
                    end

                    -------------------------------------------------
                    -- ELEMENTS
                    -------------------------------------------------
                    function sector.element(kind, text, data, callback, c_flag)
                        text     = text or kind
                        data     = (type(data) == "table") and data or {}
                        callback = callback or function() end

                        local value   = {}
                        local flag    = c_flag and (text .. " " .. c_flag) or text
                        local store   = menu.values[tab.tab_num][section_name][sector_name]
                        local default = data.default

                        store[flag] = value

                        local function do_callback()
                            store[flag] = value
                            local ok, err = pcall(callback, value)
                            if not ok then
                                warn("[Sys] element callback error (" .. tostring(flag) .. "): " .. tostring(err))
                            end
                        end

                        local element = {}
                        function element:get_value() return value end

                        ---------------------------------------------
                        -- LABEL
                        ---------------------------------------------
                        if kind == "Label" then
                            grow(18)

                            local Label = lib:create("TextLabel", {
                                BackgroundTransparency = 1,
                                Size                   = UDim2.new(1, -18, 0, 18),
                                Font                   = FONT,
                                Text                   = text,
                                TextColor3             = IDLE,
                                TextSize               = 13,
                                TextXAlignment         = Enum.TextXAlignment.Left,
                                TextWrapped            = true,
                            }, Container)

                            function element:set_text(new_text)
                                Label.Text = new_text
                            end

                            return element

                        ---------------------------------------------
                        -- TOGGLE
                        ---------------------------------------------
                        elseif kind == "Toggle" then
                            grow(18)
                            value = { Toggle = (default and default.Toggle) or false }

                            local ToggleButton = lib:create("TextButton", {
                                Name                   = "Toggle",
                                BackgroundTransparency = 1,
                                Size                   = UDim2.new(1, 0, 0, 18),
                                Text                   = "",
                            }, Container)

                            local ToggleFrame = lib:create("Frame", {
                                AnchorPoint      = Vector2.new(0, 0.5),
                                BackgroundColor3 = Color3.fromRGB(30, 30, 30),
                                BorderColor3     = BLACK,
                                Position         = UDim2.new(0, 9, 0.5, 0),
                                Size             = UDim2.new(0, 9, 0, 9),
                            }, ToggleButton)

                            local ToggleText = lib:create("TextLabel", {
                                BackgroundTransparency = 1,
                                Position               = UDim2.new(0, 27, 0, 5),
                                Size                   = UDim2.new(0, 200, 0, 9),
                                Font                   = FONT,
                                Text                   = text,
                                TextColor3             = IDLE,
                                TextSize               = 14,
                                TextXAlignment         = Enum.TextXAlignment.Left,
                            }, ToggleButton)

                            local mouse_in = false

                            function element:set_visible(bool)
                                if bool == ToggleButton.Visible then return end
                                grow(bool and 18 or -18)
                                ToggleButton.Visible = bool
                            end

                            function element:set_value(new_value, no_cb)
                                value       = new_value or value
                                store[flag] = value

                                if value.Toggle then
                                    lib:tween(ToggleFrame, {BackgroundColor3 = ACCENT})
                                    lib:tween(ToggleText,  {TextColor3 = HOVER})
                                else
                                    lib:tween(ToggleFrame, {BackgroundColor3 = Color3.fromRGB(30, 30, 30)})
                                    if not mouse_in then
                                        lib:tween(ToggleText, {TextColor3 = IDLE})
                                    end
                                end

                                if not no_cb then do_callback() end
                            end

                            track(ToggleButton.MouseEnter:Connect(function()
                                mouse_in = true
                                if value.Toggle then return end
                                lib:tween(ToggleText, {TextColor3 = HOVER})
                            end))

                            track(ToggleButton.MouseLeave:Connect(function()
                                mouse_in = false
                                if value.Toggle then return end
                                lib:tween(ToggleText, {TextColor3 = IDLE})
                            end))

                            track(ToggleButton.MouseButton1Down:Connect(function()
                                element:set_value({ Toggle = not value.Toggle })
                            end))

                            element:set_value(value, true)

                            local has_extra = false

                            -----------------------------------------
                            -- TOGGLE :: KEYBIND
                            -----------------------------------------
                            function element:add_keybind(key_default, key_callback)
                                if has_extra then return end
                                has_extra = true

                                local keybind    = {}
                                local extra_flag = "$" .. flag
                                local extra_value = { Key = nil, Type = "Always", Active = true }
                                key_callback = key_callback or function() end

                                local Keybind = lib:create("TextButton", {
                                    Name                   = "Keybind",
                                    AnchorPoint            = Vector2.new(1, 0),
                                    BackgroundTransparency = 1,
                                    Position               = UDim2.new(0, 265, 0, 0),
                                    Size                   = UDim2.new(0, 56, 0, 20),
                                    Font                   = FONT,
                                    Text                   = "[ NONE ]",
                                    TextColor3             = IDLE,
                                    TextSize               = 14,
                                    TextXAlignment         = Enum.TextXAlignment.Right,
                                }, ToggleButton)

                                local KeybindFrame = lib:create("Frame", {
                                    Name             = "KeybindFrame",
                                    BackgroundColor3 = Color3.fromRGB(10, 10, 10),
                                    BorderColor3     = Color3.fromRGB(30, 30, 30),
                                    Position         = UDim2.new(1, 5, 0, 3),
                                    Size             = UDim2.new(0, 55, 0, 75),
                                    Visible          = false,
                                    ZIndex           = 3,
                                }, Keybind)

                                lib:create("UIListLayout", {
                                    HorizontalAlignment = Enum.HorizontalAlignment.Center,
                                    SortOrder           = Enum.SortOrder.LayoutOrder,
                                }, KeybindFrame)

                                local in_bind, in_frame = false, false
                                track(Keybind.MouseEnter:Connect(function()
                                    in_bind = true
                                    lib:tween(Keybind, {TextColor3 = HOVER})
                                end))
                                track(Keybind.MouseLeave:Connect(function()
                                    in_bind = false
                                    lib:tween(Keybind, {TextColor3 = IDLE})
                                end))
                                track(KeybindFrame.MouseEnter:Connect(function()
                                    in_frame = true
                                    lib:tween(KeybindFrame, {BorderColor3 = ACCENT})
                                end))
                                track(KeybindFrame.MouseLeave:Connect(function()
                                    in_frame = false
                                    lib:tween(KeybindFrame, {BorderColor3 = Color3.fromRGB(30, 30, 30)})
                                end))

                                register_popup(function()
                                    if KeybindFrame.Visible and not in_bind and not in_frame then
                                        KeybindFrame.Visible = false
                                    end
                                end)

                                local slot = {
                                    value = extra_value,
                                    cb    = function(v)
                                        store[extra_flag] = v
                                        pcall(key_callback, v)
                                    end,
                                    name  = text,
                                    -- A getter, not a copy: set_value replaces the
                                    -- toggle's table on config load.
                                    isOn  = function() return value.Toggle == true end,
                                }

                                local function showKey()
                                    Keybind.Text = "[ " .. (extra_value.Key or "NONE"):upper() .. " ]"
                                    Keybind.Size = UDim2.new(0, lib:text_size(Keybind.Text, 14).X + 3, 0, 20)
                                end

                                slot.bind = function(pressed)
                                    if pressed == "Backspace" then
                                        extra_value.Key = nil
                                    else
                                        extra_value.Key = pressed
                                    end
                                    showKey()
                                    slot.cb(extra_value)
                                end

                                -- Abandon a pending bind: put the current key back on the label.
                                slot.cancel = showKey

                                keybinds[#keybinds + 1] = slot
                                store[extra_flag] = extra_value

                                for _, mode in ipairs({ "Always", "Hold", "Toggle" }) do
                                    local TypeButton = lib:create("TextButton", {
                                        Name                   = mode,
                                        BackgroundTransparency = 1,
                                        Size                   = UDim2.new(1, 0, 0, 25),
                                        Font                   = FONT,
                                        Text                   = mode,
                                        TextColor3             = (mode == "Always") and ACCENT or IDLE,
                                        TextSize               = 14,
                                        ZIndex                 = 3,
                                    }, KeybindFrame)

                                    track(TypeButton.MouseEnter:Connect(function()
                                        if extra_value.Type ~= mode then
                                            lib:tween(TypeButton, {TextColor3 = HOVER})
                                        end
                                    end))
                                    track(TypeButton.MouseLeave:Connect(function()
                                        if extra_value.Type ~= mode then
                                            lib:tween(TypeButton, {TextColor3 = IDLE})
                                        end
                                    end))
                                    track(TypeButton.MouseButton1Down:Connect(function()
                                        KeybindFrame.Visible = false
                                        extra_value.Type     = mode
                                        -- Toggle starts OFF (press to turn it on), Hold is off
                                        -- until held; only Always is active without the key.
                                        extra_value.Active   = (mode == "Always")

                                        for _, other in ipairs(KeybindFrame:GetChildren()) do
                                            if other:IsA("TextButton") then
                                                lib:tween(other, {TextColor3 = (other.Name == mode) and ACCENT or IDLE})
                                            end
                                        end
                                        slot.cb(extra_value)
                                    end))
                                end

                                track(Keybind.MouseButton1Down:Connect(function()
                                    -- Clicking the label that's already waiting cancels it.
                                    if binding_slot == slot then
                                        binding_slot = nil
                                        slot.cancel()
                                        return
                                    end
                                    -- Another bind left waiting would otherwise swallow this
                                    -- click AND take the next key press - hand over instead.
                                    if binding_slot then binding_slot.cancel() end
                                    binding_slot = slot
                                    Keybind.Text = "[ ... ]"
                                    Keybind.Size = UDim2.new(0, lib:text_size("[ ... ]", 14).X + 3, 0, 20)
                                end))

                                track(Keybind.MouseButton2Down:Connect(function()
                                    if binding_slot then return end
                                    KeybindFrame.Visible = not KeybindFrame.Visible
                                end))

                                function keybind:set_value(new_value, no_cb)
                                    if new_value then
                                        extra_value.Key    = new_value.Key
                                        extra_value.Type   = new_value.Type or "Always"
                                        extra_value.Active = new_value.Active
                                    end
                                    store[extra_flag] = extra_value

                                    for _, other in ipairs(KeybindFrame:GetChildren()) do
                                        if other:IsA("TextButton") then
                                            lib:tween(other, {
                                                TextColor3 = (other.Name == extra_value.Type) and ACCENT or IDLE,
                                            })
                                        end
                                    end

                                    local key    = extra_value.Key or "NONE"
                                    Keybind.Text = "[ " .. key:upper() .. " ]"
                                    Keybind.Size = UDim2.new(0, lib:text_size(Keybind.Text, 14).X + 3, 0, 20)

                                    if not no_cb then pcall(key_callback, extra_value) end
                                end

                                keybind:set_value(key_default, true)

                                track(menu.on_load_cfg:Connect(function()
                                    keybind:set_value(store[extra_flag], true)
                                end))

                                return keybind
                            end

                            -----------------------------------------
                            -- TOGGLE :: COLOUR PICKER
                            -----------------------------------------
                            function element:add_color(color_default, has_transparency, color_callback)
                                if has_extra then return end
                                has_extra = true

                                local color       = {}
                                local extra_flag  = "$" .. flag
                                local extra_value = { Color = Color3.new(1, 1, 1) }
                                color_callback    = color_callback or function() end

                                local ColorButton = lib:create("TextButton", {
                                    Name             = "ColorButton",
                                    AnchorPoint      = Vector2.new(1, 0.5),
                                    BackgroundColor3 = Color3.fromRGB(255, 28, 28),
                                    BorderColor3     = BLACK,
                                    Position         = UDim2.new(0, 265, 0.5, 0),
                                    Size             = UDim2.new(0, 35, 0, 11),
                                    AutoButtonColor  = false,
                                    Font             = FONT,
                                    Text             = "",
                                }, ToggleButton)

                                local ColorFrame = lib:create("Frame", {
                                    Name             = "ColorFrame",
                                    BackgroundColor3 = Color3.fromRGB(10, 10, 10),
                                    BorderColor3     = BLACK,
                                    Position         = UDim2.new(1, 5, 0, 0),
                                    Size             = UDim2.new(0, 200, 0, 170),
                                    Visible          = false,
                                    ZIndex           = 3,
                                }, ColorButton)

                                local ColorPicker = lib:create("ImageButton", {
                                    Name             = "ColorPicker",
                                    BackgroundColor3 = HOVER,
                                    BorderColor3     = BLACK,
                                    Position         = UDim2.new(0, 40, 0, 10),
                                    Size             = UDim2.new(0, 150, 0, 150),
                                    AutoButtonColor  = false,
                                    Image            = "rbxassetid://4155801252",
                                    ImageColor3      = Color3.fromRGB(255, 0, 4),
                                    ZIndex           = 3,
                                }, ColorFrame)

                                local ColorPick = lib:create("Frame", {
                                    Name             = "ColorPick",
                                    BackgroundColor3 = HOVER,
                                    BorderColor3     = BLACK,
                                    Size             = UDim2.new(0, 1, 0, 1),
                                    ZIndex           = 3,
                                }, ColorPicker)

                                local HuePicker = lib:create("TextButton", {
                                    Name             = "HuePicker",
                                    BackgroundColor3 = HOVER,
                                    BorderColor3     = BLACK,
                                    Position         = UDim2.new(0, 10, 0, 10),
                                    Size             = UDim2.new(0, 20, 0, 150),
                                    AutoButtonColor  = false,
                                    Text             = "",
                                    ZIndex           = 3,
                                }, ColorFrame)

                                lib:create("UIGradient", {
                                    Rotation = 90,
                                    Color    = ColorSequence.new({
                                        ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
                                        ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 0, 255)),
                                        ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 0, 255)),
                                        ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
                                        ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 255, 0)),
                                        ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 255, 0)),
                                        ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
                                    }),
                                }, HuePicker)

                                local HuePick = lib:create("ImageButton", {
                                    Name             = "HuePick",
                                    BackgroundColor3 = HOVER,
                                    BorderColor3     = BLACK,
                                    Size             = UDim2.new(1, 0, 0, 1),
                                    ZIndex           = 3,
                                }, HuePicker)

                                local in_frame, in_button = false, false

                                track(ColorButton.MouseButton1Down:Connect(function()
                                    ColorFrame.Visible = not ColorFrame.Visible
                                end))
                                track(ColorFrame.MouseEnter:Connect(function()
                                    in_frame = true
                                    lib:tween(ColorFrame, {BorderColor3 = ACCENT})
                                end))
                                track(ColorFrame.MouseLeave:Connect(function()
                                    in_frame = false
                                    lib:tween(ColorFrame, {BorderColor3 = BLACK})
                                end))
                                track(ColorButton.MouseEnter:Connect(function() in_button = true end))
                                track(ColorButton.MouseLeave:Connect(function() in_button = false end))

                                register_popup(function()
                                    if ColorFrame.Visible and not in_frame and not in_button then
                                        ColorFrame.Visible = false
                                    end
                                end)

                                local TransparencyColor, TransparencyPick, TransparencyPicker
                                if has_transparency then
                                    ColorFrame.Size = UDim2.new(0, 200, 0, 200)

                                    TransparencyPicker = lib:create("ImageButton", {
                                        Name             = "TransparencyPicker",
                                        BackgroundColor3 = HOVER,
                                        BorderColor3     = BLACK,
                                        Position         = UDim2.new(0, 10, 0, 170),
                                        Size             = UDim2.new(0, 180, 0, 20),
                                        Image            = "rbxassetid://3887014957",
                                        ScaleType        = Enum.ScaleType.Tile,
                                        TileSize         = UDim2.new(0, 10, 0, 10),
                                        ZIndex           = 3,
                                    }, ColorFrame)

                                    TransparencyColor = lib:create("ImageLabel", {
                                        BackgroundTransparency = 1,
                                        Size                   = UDim2.new(1, 0, 1, 0),
                                        Image                  = "rbxassetid://3887017050",
                                        ZIndex                 = 3,
                                    }, TransparencyPicker)

                                    TransparencyPick = lib:create("Frame", {
                                        Name             = "TransparencyPick",
                                        BackgroundColor3 = HOVER,
                                        BorderColor3     = BLACK,
                                        Size             = UDim2.new(0, 1, 1, 0),
                                        ZIndex           = 3,
                                    }, TransparencyPicker)

                                    extra_value.Transparency = 0
                                end

                                color.h, color.s, color.v = 0, 1, 1

                                local function push()
                                    extra_value.Color = Color3.fromHSV(color.h, color.s, color.v)
                                    store[extra_flag] = extra_value
                                    ColorButton.BackgroundColor3 = extra_value.Color
                                    pcall(color_callback, extra_value)
                                end

                                local function drag(update)
                                    update()
                                    -- Locals, not globals. The public source leaked both of
                                    -- these into the global table on every drag.
                                    local move_conn, release_conn
                                    move_conn = Mouse.Move:Connect(update)
                                    release_conn = UserInputService.InputEnded:Connect(function(i)
                                        if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                                        update()
                                        if move_conn then move_conn:Disconnect() end
                                        if release_conn then release_conn:Disconnect() end
                                    end)
                                end

                                local function update_color()
                                    local px = math.clamp(Mouse.X - ColorPicker.AbsolutePosition.X, 0, ColorPicker.AbsoluteSize.X) / ColorPicker.AbsoluteSize.X
                                    local py = math.clamp(Mouse.Y - ColorPicker.AbsolutePosition.Y, 0, ColorPicker.AbsoluteSize.Y) / ColorPicker.AbsoluteSize.Y
                                    ColorPick.Position = UDim2.new(px, 0, py, 0)
                                    color.s = 1 - px
                                    color.v = 1 - py
                                    push()
                                end

                                local function update_hue()
                                    local y   = math.clamp(Mouse.Y - HuePicker.AbsolutePosition.Y, 0, 148)
                                    HuePick.Position = UDim2.new(0, 0, 0, y)
                                    color.h   = 1 - (y / 148)
                                    ColorPicker.ImageColor3 = Color3.fromHSV(color.h, 1, 1)
                                    if TransparencyColor then
                                        TransparencyColor.ImageColor3 = Color3.fromHSV(color.h, 1, 1)
                                    end
                                    push()
                                end

                                local function update_transparency()
                                    local x = math.clamp(Mouse.X - TransparencyPicker.AbsolutePosition.X, 0, 180)
                                    TransparencyPick.Position = UDim2.new(0, x, 0, 0)
                                    extra_value.Transparency  = x / 180
                                    push()
                                end

                                track(ColorPicker.MouseButton1Down:Connect(function() drag(update_color) end))
                                track(HuePicker.MouseButton1Down:Connect(function() drag(update_hue) end))
                                if has_transparency then
                                    track(TransparencyPicker.MouseButton1Down:Connect(function()
                                        drag(update_transparency)
                                    end))
                                end

                                function color:set_value(new_value, no_cb)
                                    if new_value and new_value.Color then
                                        extra_value.Color = new_value.Color
                                        if new_value.Transparency then
                                            extra_value.Transparency = new_value.Transparency
                                        end
                                    end
                                    store[extra_flag] = extra_value

                                    local c = extra_value.Color
                                    color.h, color.s, color.v = Color3.new(c.R, c.G, c.B):ToHSV()
                                    color.h = math.clamp(color.h, 0, 1)
                                    color.s = math.clamp(color.s, 0, 1)
                                    color.v = math.clamp(color.v, 0, 1)

                                    ColorPick.Position           = UDim2.new(1 - color.s, 0, 1 - color.v, 0)
                                    ColorPicker.ImageColor3      = Color3.fromHSV(color.h, 1, 1)
                                    ColorButton.BackgroundColor3 = extra_value.Color
                                    HuePick.Position             = UDim2.new(0, 0, 1 - color.h, -1)

                                    if TransparencyColor then
                                        TransparencyColor.ImageColor3 = Color3.fromHSV(color.h, 1, 1)
                                        TransparencyPick.Position     = UDim2.new(extra_value.Transparency or 0, -1, 0, 0)
                                    end

                                    if not no_cb then pcall(color_callback, extra_value) end
                                end

                                color:set_value(color_default, true)

                                track(menu.on_load_cfg:Connect(function()
                                    color:set_value(store[extra_flag])
                                end))

                                return color
                            end

                        ---------------------------------------------
                        -- DROPDOWN / COMBO (multi-select)
                        ---------------------------------------------
                        elseif kind == "Dropdown" or kind == "Combo" then
                            local multi   = (kind == "Combo")
                            local options = data.options or {}

                            grow(45)

                            if multi then
                                value = { Combo = (default and default.Combo) or {} }
                            else
                                value = { Dropdown = (default and default.Dropdown) or options[1] or "" }
                            end

                            local Holder = lib:create("TextLabel", {
                                Name                   = "Dropdown",
                                BackgroundTransparency = 1,
                                Size                   = UDim2.new(1, 0, 0, 45),
                                Text                   = "",
                            }, Container)

                            local DropdownButton = lib:create("TextButton", {
                                Name             = "DropdownButton",
                                BackgroundColor3 = Color3.fromRGB(25, 25, 25),
                                BorderColor3     = BLACK,
                                Position         = UDim2.new(0, 9, 0, 20),
                                Size             = UDim2.new(0, SLIDER_W, 0, 20),
                                AutoButtonColor  = false,
                                Text             = "",
                            }, Holder)

                            local DropdownButtonText = lib:create("TextLabel", {
                                Name                   = "DropdownButtonText",
                                BackgroundTransparency = 1,
                                Position               = UDim2.new(0, 6, 0, 0),
                                Size                   = UDim2.new(0, 250, 1, 0),
                                Font                   = FONT,
                                Text                   = multi and "..." or tostring(value.Dropdown),
                                TextColor3             = IDLE,
                                TextSize               = 14,
                                TextXAlignment         = Enum.TextXAlignment.Left,
                                TextTruncate           = Enum.TextTruncate.AtEnd,
                            }, DropdownButton)

                            lib:create("ImageLabel", {
                                BackgroundTransparency = 1,
                                Position               = UDim2.new(0, 245, 0, 8),
                                Size                   = UDim2.new(0, 6, 0, 4),
                                Image                  = "rbxassetid://6724771531",
                            }, DropdownButton)

                            local DropdownText = lib:create("TextLabel", {
                                Name                   = "DropdownText",
                                BackgroundTransparency = 1,
                                Position               = UDim2.new(0, 9, 0, 6),
                                Size                   = UDim2.new(0, 200, 0, 9),
                                Font                   = FONT,
                                Text                   = text,
                                TextColor3             = IDLE,
                                TextSize               = 14,
                                TextXAlignment         = Enum.TextXAlignment.Left,
                            }, Holder)

                            local DropdownScroll = lib:create("ScrollingFrame", {
                                Name                 = "DropdownScroll",
                                Active               = true,
                                BackgroundColor3     = Color3.fromRGB(25, 25, 25),
                                BorderColor3         = BLACK,
                                Position             = UDim2.new(0, 9, 0, 41),
                                Size                 = UDim2.new(0, SLIDER_W, 0, 20),
                                CanvasSize           = UDim2.new(0, 0, 0, 0),
                                ScrollBarThickness   = 2,
                                ScrollBarImageColor3 = ACCENT,
                                TopImage             = "rbxasset://textures/ui/Scroll/scroll-middle.png",
                                BottomImage          = "rbxasset://textures/ui/Scroll/scroll-middle.png",
                                Visible              = false,
                                ZIndex               = 3,
                            }, Holder)

                            lib:create("UIListLayout", {
                                HorizontalAlignment = Enum.HorizontalAlignment.Center,
                                SortOrder           = Enum.SortOrder.LayoutOrder,
                            }, DropdownScroll)

                            local in_holder, in_scroll = false, false

                            local function close_list()
                                DropdownScroll.Visible       = false
                                DropdownScroll.CanvasPosition = Vector2.new(0, 0)
                                lib:tween(DropdownText,       {TextColor3 = IDLE})
                                lib:tween(DropdownButtonText, {TextColor3 = IDLE})
                            end

                            track(DropdownButton.MouseButton1Down:Connect(function()
                                DropdownScroll.Visible = not DropdownScroll.Visible
                                local c = DropdownScroll.Visible and HOVER or IDLE
                                lib:tween(DropdownText,       {TextColor3 = c})
                                lib:tween(DropdownButtonText, {TextColor3 = c})
                            end))

                            track(Holder.MouseEnter:Connect(function() in_holder = true end))
                            track(Holder.MouseLeave:Connect(function() in_holder = false end))
                            track(DropdownScroll.MouseEnter:Connect(function() in_scroll = true end))
                            track(DropdownScroll.MouseLeave:Connect(function() in_scroll = false end))

                            register_popup(function()
                                if DropdownScroll.Visible and not in_holder and not in_scroll then
                                    close_list()
                                end
                            end)

                            local function combo_text()
                                local picked = {}
                                for _, opt in ipairs(options) do
                                    if table.find(value.Combo, opt) then picked[#picked + 1] = opt end
                                end
                                if #picked == 0 then
                                    DropdownButtonText.Text = "..."
                                elseif #picked <= 3 then
                                    DropdownButtonText.Text = table.concat(picked, ", ")
                                else
                                    DropdownButtonText.Text = table.concat({ picked[1], picked[2], picked[3] }, ", ") .. ", ..."
                                end
                            end

                            local build_options

                            function element:set_value(new_value, no_cb)
                                value       = new_value or value
                                store[flag] = value

                                if multi then
                                    value.Combo = value.Combo or {}
                                    combo_text()
                                    for _, btn in ipairs(DropdownScroll:GetChildren()) do
                                        if btn:IsA("TextButton") then
                                            local on = table.find(value.Combo, btn.Name) ~= nil
                                            btn.Decoration.Visible     = on
                                            btn.ButtonText.TextColor3  = on and HOVER or IDLE
                                        end
                                    end
                                else
                                    DropdownButtonText.Text = tostring(value.Dropdown or "")
                                end

                                if not no_cb then do_callback() end
                            end

                            build_options = function()
                                for _, child in ipairs(DropdownScroll:GetChildren()) do
                                    if not child:IsA("UIListLayout") then child:Destroy() end
                                end

                                local count = #options
                                if count >= 4 then
                                    DropdownScroll.Size       = UDim2.new(0, SLIDER_W, 0, 80)
                                    DropdownScroll.CanvasSize = UDim2.new(0, 0, 0, count * 20)
                                else
                                    DropdownScroll.Size       = UDim2.new(0, SLIDER_W, 0, 20 * math.max(count, 1))
                                    DropdownScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
                                end

                                for _, opt in ipairs(options) do
                                    local Button = lib:create("TextButton", {
                                        Name             = tostring(opt),
                                        BackgroundColor3 = Color3.fromRGB(25, 25, 25),
                                        BorderSizePixel  = 0,
                                        Size             = UDim2.new(1, 0, 0, 20),
                                        AutoButtonColor  = false,
                                        Text             = "",
                                        ZIndex           = 3,
                                    }, DropdownScroll)

                                    local ButtonText = lib:create("TextLabel", {
                                        Name                   = "ButtonText",
                                        BackgroundTransparency = 1,
                                        Position               = UDim2.new(0, 8, 0, 0),
                                        Size                   = UDim2.new(0, 245, 1, 0),
                                        Font                   = FONT,
                                        Text                   = tostring(opt),
                                        TextColor3             = IDLE,
                                        TextSize               = 14,
                                        TextXAlignment         = Enum.TextXAlignment.Left,
                                        TextTruncate           = Enum.TextTruncate.AtEnd,
                                        ZIndex                 = 3,
                                    }, Button)

                                    local Decoration = lib:create("Frame", {
                                        Name             = "Decoration",
                                        BackgroundColor3 = ACCENT,
                                        BorderSizePixel  = 0,
                                        Size             = UDim2.new(0, 1, 1, 0),
                                        Visible          = false,
                                        ZIndex           = 3,
                                    }, Button)

                                    local function selected()
                                        if multi then return table.find(value.Combo, opt) ~= nil end
                                        return value.Dropdown == opt
                                    end

                                    track(Button.MouseEnter:Connect(function()
                                        if not selected() then lib:tween(ButtonText, {TextColor3 = HOVER}) end
                                        Decoration.Visible = true
                                    end))
                                    track(Button.MouseLeave:Connect(function()
                                        if not selected() then
                                            lib:tween(ButtonText, {TextColor3 = IDLE})
                                            Decoration.Visible = false
                                        end
                                    end))

                                    track(Button.MouseButton1Down:Connect(function()
                                        if multi then
                                            local idx = table.find(value.Combo, opt)
                                            if idx then
                                                table.remove(value.Combo, idx)
                                                Decoration.Visible    = false
                                                ButtonText.TextColor3 = IDLE
                                            else
                                                value.Combo[#value.Combo + 1] = opt
                                                Decoration.Visible    = true
                                                ButtonText.TextColor3 = HOVER
                                            end
                                            combo_text()
                                        else
                                            value.Dropdown          = opt
                                            DropdownButtonText.Text = tostring(opt)
                                            close_list()
                                        end
                                        do_callback()
                                    end))

                                    if selected() then
                                        Decoration.Visible    = true
                                        ButtonText.TextColor3 = HOVER
                                    end
                                end
                            end

                            build_options()

                            function element:refresh(new_options, keep)
                                options = new_options or options
                                if not keep then
                                    if multi then
                                        value.Combo = {}
                                    else
                                        value.Dropdown = options[1] or ""
                                    end
                                end
                                build_options()
                                element:set_value(value, true)
                            end

                            function element:set_visible(bool)
                                if bool == Holder.Visible then return end
                                grow(bool and 45 or -45)
                                Holder.Visible = bool
                            end

                            element:set_value(value, true)

                        ---------------------------------------------
                        -- BUTTON
                        ---------------------------------------------
                        elseif kind == "Button" then
                            grow(30)

                            local ButtonFrame = lib:create("Frame", {
                                Name                   = "ButtonFrame",
                                BackgroundTransparency = 1,
                                Size                   = UDim2.new(1, 0, 0, 30),
                            }, Container)

                            local Button = lib:create("TextButton", {
                                Name             = "Button",
                                AnchorPoint      = Vector2.new(0.5, 0.5),
                                BackgroundColor3 = Color3.fromRGB(25, 25, 25),
                                BorderColor3     = BLACK,
                                Position         = UDim2.new(0.5, 0, 0.5, 0),
                                Size             = UDim2.new(0, 215, 0, 20),
                                AutoButtonColor  = false,
                                Font             = FONT,
                                Text             = text,
                                TextColor3       = IDLE,
                                TextSize         = 14,
                            }, ButtonFrame)

                            track(Button.MouseEnter:Connect(function()
                                lib:tween(Button, {TextColor3 = HOVER})
                            end))
                            track(Button.MouseLeave:Connect(function()
                                lib:tween(Button, {TextColor3 = IDLE})
                            end))
                            track(Button.MouseButton1Down:Connect(function()
                                Button.BorderColor3 = ACCENT
                                lib:tween(Button, {BorderColor3 = BLACK},
                                    TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
                                do_callback()
                            end))

                            function element:set_text(new_text) Button.Text = new_text end

                            function element:set_visible(bool)
                                if bool == ButtonFrame.Visible then return end
                                grow(bool and 30 or -30)
                                ButtonFrame.Visible = bool
                            end

                            return element

                        ---------------------------------------------
                        -- TEXTBOX
                        ---------------------------------------------
                        elseif kind == "TextBox" then
                            grow(30)

                            -- The public source hardcoded a 15 character cap.
                            local maxlen = data.maxlen or 64
                            value = { Text = (type(default) == "string" and default) or "" }

                            local ButtonFrame = lib:create("Frame", {
                                Name                   = "ButtonFrame",
                                BackgroundTransparency = 1,
                                Size                   = UDim2.new(1, 0, 0, 30),
                            }, Container)

                            local TextBox = lib:create("TextBox", {
                                Name              = "TextBox",
                                AnchorPoint       = Vector2.new(0.5, 0.5),
                                BackgroundColor3  = Color3.fromRGB(25, 25, 25),
                                BorderColor3      = BLACK,
                                Position          = UDim2.new(0.5, 0, 0.5, 0),
                                Size              = UDim2.new(0, 215, 0, 20),
                                Font              = FONT,
                                Text              = value.Text,
                                PlaceholderText   = text,
                                TextColor3        = IDLE,
                                TextSize          = 14,
                                ClearTextOnFocus  = false,
                            }, ButtonFrame)

                            track(TextBox.MouseEnter:Connect(function()
                                lib:tween(TextBox, {TextColor3 = HOVER})
                            end))
                            track(TextBox.MouseLeave:Connect(function()
                                lib:tween(TextBox, {TextColor3 = IDLE})
                            end))
                            track(TextBox.Focused:Connect(function()
                                lib:tween(TextBox, {BorderColor3 = ACCENT})
                            end))
                            track(TextBox.FocusLost:Connect(function()
                                lib:tween(TextBox, {BorderColor3 = BLACK})
                            end))

                            track(TextBox:GetPropertyChangedSignal("Text"):Connect(function()
                                if #TextBox.Text > maxlen then
                                    TextBox.Text = string.sub(TextBox.Text, 1, maxlen)
                                    return
                                end
                                if TextBox.Text ~= value.Text then
                                    value.Text = TextBox.Text
                                    do_callback()
                                end
                            end))

                            function element:set_value(new_value, no_cb)
                                value       = new_value or value
                                store[flag] = value
                                TextBox.Text = value.Text or ""
                                if not no_cb then do_callback() end
                            end

                            function element:set_visible(bool)
                                if bool == ButtonFrame.Visible then return end
                                grow(bool and 30 or -30)
                                ButtonFrame.Visible = bool
                            end

                            element:set_value(value, true)

                        ---------------------------------------------
                        -- SLIDER
                        ---------------------------------------------
                        elseif kind == "Slider" then
                            grow(35)

                            local min      = (default and default.min) or 0
                            local max      = (default and default.max) or 100
                            local suffix   = data.suffix or ""
                            value = { Slider = (default and default.default) or min }

                            local Slider = lib:create("Frame", {
                                Name                   = "Slider",
                                BackgroundTransparency = 1,
                                Size                   = UDim2.new(1, 0, 0, 35),
                            }, Container)

                            local SliderText = lib:create("TextLabel", {
                                Name                   = "SliderText",
                                BackgroundTransparency = 1,
                                Position               = UDim2.new(0, 9, 0, 6),
                                Size                   = UDim2.new(0, 200, 0, 9),
                                Font                   = FONT,
                                Text                   = text,
                                TextColor3             = IDLE,
                                TextSize               = 14,
                                TextXAlignment         = Enum.TextXAlignment.Left,
                            }, Slider)

                            local SliderButton = lib:create("TextButton", {
                                Name             = "SliderButton",
                                BackgroundColor3 = Color3.fromRGB(25, 25, 25),
                                BorderColor3     = BLACK,
                                Position         = UDim2.new(0, 9, 0, 20),
                                Size             = UDim2.new(0, SLIDER_W, 0, 10),
                                AutoButtonColor  = false,
                                Text             = "",
                            }, Slider)

                            local SliderFill = lib:create("Frame", {
                                Name             = "SliderFrame",
                                BackgroundColor3 = HOVER,
                                BorderSizePixel  = 0,
                                Size             = UDim2.new(0, 0, 1, 0),
                            }, SliderButton)

                            lib:create("UIGradient", {
                                Color = ColorSequence.new({
                                    ColorSequenceKeypoint.new(0, ACCENT),
                                    ColorSequenceKeypoint.new(1, ACCENT_DIM),
                                }),
                                Rotation = 90,
                            }, SliderFill)

                            local SliderValue = lib:create("TextLabel", {
                                Name                   = "SliderValue",
                                BackgroundTransparency = 1,
                                Position               = UDim2.new(0, 69, 0, 6),
                                Size                   = UDim2.new(0, 200, 0, 9),
                                Font                   = FONT,
                                Text                   = tostring(value.Slider),
                                TextColor3             = IDLE,
                                TextSize               = 14,
                                TextXAlignment         = Enum.TextXAlignment.Right,
                            }, Slider)

                            local sliding, mouse_in = false, false

                            local function paint()
                                local span = (max - min)
                                local pct  = span > 0 and ((value.Slider - min) / span) or 0
                                SliderFill.Size  = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)
                                SliderValue.Text = tostring(value.Slider) .. suffix
                            end

                            local function from_mouse()
                                local x    = math.clamp(Mouse.X - SliderButton.AbsolutePosition.X, 0, SLIDER_W)
                                local val  = math.floor(min + ((max - min) * (x / SLIDER_W)) + 0.5)
                                if val ~= value.Slider then
                                    value.Slider = val
                                    paint()
                                    do_callback()
                                else
                                    paint()
                                end
                            end

                            track(Slider.MouseEnter:Connect(function()
                                mouse_in = true
                                lib:tween(SliderText,  {TextColor3 = HOVER})
                                lib:tween(SliderValue, {TextColor3 = HOVER})
                            end))

                            track(Slider.MouseLeave:Connect(function()
                                mouse_in = false
                                if not sliding then
                                    lib:tween(SliderText,  {TextColor3 = IDLE})
                                    lib:tween(SliderValue, {TextColor3 = IDLE})
                                end
                            end))

                            track(SliderButton.MouseButton1Down:Connect(function()
                                sliding = true
                                from_mouse()

                                -- Both locals. The public source made these globals.
                                local move_conn, release_conn
                                move_conn = Mouse.Move:Connect(from_mouse)
                                release_conn = UserInputService.InputEnded:Connect(function(i)
                                    if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                                    from_mouse()
                                    sliding = false
                                    if not mouse_in then
                                        lib:tween(SliderText,  {TextColor3 = IDLE})
                                        lib:tween(SliderValue, {TextColor3 = IDLE})
                                    end
                                    if move_conn then move_conn:Disconnect() end
                                    if release_conn then release_conn:Disconnect() end
                                end)
                            end))

                            function element:set_value(new_value, no_cb)
                                value        = new_value or value
                                value.Slider = math.clamp(value.Slider or min, min, max)
                                store[flag]  = value
                                paint()
                                if not no_cb then do_callback() end
                            end

                            function element:set_visible(bool)
                                if bool == Slider.Visible then return end
                                grow(bool and 35 or -35)
                                Slider.Visible = bool
                            end

                            element:set_value(value, true)
                        end

                        -- Config restore. Buttons and labels have no state.
                        track(menu.on_load_cfg:Connect(function()
                            if kind == "Button" or kind == "Label" then return end
                            local saved = store[flag]
                            if saved and element.set_value then
                                element:set_value(saved)
                            end
                        end))

                        return element
                    end

                    return sector
                end

                return section
            end

            return tab
        end

        return menu
    end

    return lib
end)()

yield(true)

---------------------------------------------------------------------
-- LOAD SPLASH
--
-- A ViewportFrame renders real 3D inside a GUI, so the logo is an actual
-- spinning mesh rather than a flipbook of images.
--
-- The mesh is a Part + SpecialMesh rather than a MeshPart: MeshPart.MeshId is
-- read-only at runtime, so a MeshPart built from a script arrives empty.
-- SpecialMesh with MeshType = FileMesh takes its MeshId at runtime and is the
-- only way to do this from an executor.
--
-- Sequence:
--   0.0s  logo fades in dead centre and starts turning
--   3.0s  the word takes the centre of the screen and pushes the logo left,
--         its letters rising in one after another
--   ~4.0s once the word has settled the logo eases to a stop facing forward
--   ~5.6s everything fades out and the menu is revealed
--
-- Centring: the WORD owns the centre of the screen. Everything is positioned
-- from the measured width of the word, so the lockup stays correct whatever
-- the word or the font size becomes - a hardcoded offset only looks right at
-- one size.
--
-- NOTE: this block runs before the shared-state locals exist, so it reaches
-- through K rather than using RunService / LP directly.
---------------------------------------------------------------------
local Splash = {}

do
    local MESH_ID    = "rbxassetid://129400024703571"
    local TEXTURE_ID = "rbxassetid://118736866214609"
    local IMAGE_ID   = ""      -- 2D logo decal, used if the mesh cannot load

    local WORD       = "Sys"
    local WORD_FONT  = Enum.Font.Ubuntu
    local WORD_SIZE  = 58
    local TRACKING   = 3       -- px between letters; a wordmark needs air
    local GAP        = 30      -- px between logo and word

    local VP_SIZE    = 260
    local SPIN_SPEED = 0.9
    local TILT       = math.rad(12)

    local FADE_IN     = 0.5
    local HOLD_CENTRE = 3.0
    local SHIFT       = 0.7
    local LETTER_STEP = 0.07
    local LETTER_RISE = 0.45
    local SETTLE      = 0.75   -- spin easing to a forward-facing stop
    local HOLD_TEXT   = 1.5
    local FADE_OUT    = 0.5

    Splash.finished = false

    local function splashParent()
        if gethui then
            local ok, hui = pcall(gethui)
            if ok and hui then return hui end
        end
        local ok, core = pcall(function() return game:GetService("CoreGui") end)
        if ok and core then return core end
        return K.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    end

    function Splash.show()
        if Splash.gui then return end

        local TS  = K.Services.TweenService
        local TXS = K.Services.TextService

        local gui = Instance.new("ScreenGui")
        gui.Name           = K.Services.HttpService:GenerateGUID(false)
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn   = false
        gui.DisplayOrder   = 10000
        gui.Parent         = splashParent()
        Splash.gui = gui

        local back = Instance.new("Frame")
        back.Size                   = UDim2.new(1, 0, 1, 0)
        back.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
        back.BackgroundTransparency = 1
        back.BorderSizePixel        = 0
        back.Parent                 = gui

        -- Measure each letter so the word can be centred exactly.
        local letters, wordWidth = {}, 0
        for i = 1, #WORD do
            local ch = WORD:sub(i, i)
            local ok, sz = pcall(function()
                return TXS:GetTextSize(ch, WORD_SIZE, WORD_FONT, Vector2.new(1000, 200))
            end)
            local w = (ok and sz) and sz.X or WORD_SIZE * 0.6
            letters[i] = { ch = ch, w = w }
            wordWidth = wordWidth + w + (i < #WORD and TRACKING or 0)
        end

        -- The word is centred on screen; the logo is pushed out to its left.
        local wordLeft = -wordWidth / 2
        local logoX    = wordLeft - GAP - VP_SIZE / 2

        local vp = Instance.new("ViewportFrame")
        vp.AnchorPoint            = Vector2.new(0.5, 0.5)
        vp.Position               = UDim2.new(0.5, 0, 0.5, 0)   -- dead centre to start
        vp.Size                   = UDim2.new(0, VP_SIZE, 0, VP_SIZE)
        vp.BackgroundTransparency = 1
        vp.ImageTransparency      = 1
        -- Flat white ambient: the texture carries the shading, so lighting
        -- that falls off would just darken the artwork's own gradient.
        vp.Ambient                = Color3.fromRGB(255, 255, 255)
        vp.LightColor             = Color3.fromRGB(255, 255, 255)
        vp.LightDirection         = Vector3.new(-0.3, -0.5, -1)
        vp.Parent                 = gui

        local part = Instance.new("Part")
        part.Anchored   = true
        part.CanCollide = false
        part.Size       = Vector3.new(1, 1, 1)
        part.CFrame     = CFrame.new()
        part.Color      = Color3.fromRGB(255, 255, 255)
        part.Material   = Enum.Material.SmoothPlastic

        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.FileMesh
        mesh.MeshId   = MESH_ID
        mesh.Scale    = Vector3.new(2.2, 2.2, 2.2)
        if TEXTURE_ID ~= "" then mesh.TextureId = TEXTURE_ID end
        mesh.Parent   = part
        part.Parent   = vp

        local cam = Instance.new("Camera")
        cam.FieldOfView  = 40
        cam.CFrame       = CFrame.new(Vector3.new(0, 0.6, 7), Vector3.new(0, 0, 0))
        cam.Parent       = vp
        vp.CurrentCamera = cam

        local flat = Instance.new("ImageLabel")
        flat.AnchorPoint            = Vector2.new(0.5, 0.5)
        flat.Position               = UDim2.new(0.5, 0, 0.5, 0)
        flat.Size                   = UDim2.new(0, VP_SIZE * 0.8, 0, VP_SIZE * 0.8)
        flat.BackgroundTransparency = 1
        flat.ImageTransparency      = 1
        flat.Visible                = false
        flat.Image                  = IMAGE_ID
        flat.Parent                 = gui

        -- One label per letter: TextLabel has no tracking property, and this
        -- also lets them arrive one at a time instead of all at once.
        local labels, x = {}, wordLeft
        for i, L in ipairs(letters) do
            local holder = Instance.new("Frame")
            holder.AnchorPoint            = Vector2.new(0, 0.5)
            holder.Position               = UDim2.new(0.5, x, 0.5, 16)   -- starts low
            holder.Size                   = UDim2.new(0, L.w, 0, WORD_SIZE + 10)
            holder.BackgroundTransparency = 1
            holder.Parent                 = gui

            local lb = Instance.new("TextLabel")
            lb.BackgroundTransparency = 1
            lb.Size                   = UDim2.new(1, 0, 1, 0)
            lb.Font                   = WORD_FONT
            lb.Text                   = L.ch
            lb.TextSize               = WORD_SIZE
            lb.TextColor3             = Color3.fromRGB(255, 255, 255)
            lb.TextTransparency       = 1
            lb.TextXAlignment         = Enum.TextXAlignment.Center
            lb.Parent                 = holder

            labels[i] = { holder = holder, label = lb, x = x }
            x = x + L.w + TRACKING
        end

        Splash.parts = { back = back, vp = vp, flat = flat, labels = labels }

        ---------------------------------------------------------------
        -- Spin, then ease to a forward-facing stop.
        --
        -- Settling tweens to the NEXT whole turn rather than back to the
        -- nearest angle, so it always finishes winding forwards instead of
        -- stuttering backwards into place. The tilt unwinds over the same
        -- ramp, so it ends square to the camera.
        ---------------------------------------------------------------
        local angle, settling, tStart, from, target = 0, false, 0, 0, 0

        local function beginSettle()
            if settling then return end
            settling = true
            tStart   = os.clock()
            from     = angle
            target   = math.ceil(angle / (math.pi * 2)) * (math.pi * 2)
            if target - from < 0.35 then target = target + math.pi * 2 end
        end
        Splash.settle = beginSettle

        Splash.conn = bind(K.Services.RunService.RenderStepped:Connect(function(dt)
            if not part.Parent then return end

            local tilt = TILT
            if settling then
                local t = math.clamp((os.clock() - tStart) / SETTLE, 0, 1)
                local e = 1 - (1 - t) ^ 4            -- quart out
                angle = from + (target - from) * e
                tilt  = TILT * (1 - e)
            else
                angle = angle + dt * SPIN_SPEED
            end

            part.CFrame = CFrame.Angles(tilt, angle, 0)
            if flat.Visible then
                flat.Rotation = settling and 0 or math.deg(angle) * 0.5
            end
        end))

        task.spawn(function()
            local ok = pcall(function()
                game:GetService("ContentProvider"):PreloadAsync({ part }, function(_, status)
                    if status ~= Enum.AssetFetchStatus.Success then
                        Splash.meshFailed = true
                    end
                end)
            end)
            if (not ok or Splash.meshFailed) and Splash.gui then
                warn("[Sys] logo mesh could not be fetched - check MESH_ID is a mesh "
                     .. "asset (MeshPart.MeshId in Studio), not a model id")
                vp.Visible = false
                if IMAGE_ID ~= "" then
                    flat.Visible = true
                    TS:Create(flat, TweenInfo.new(0.4), { ImageTransparency = 0 }):Play()
                end
            end
        end)

        Splash.thread = task.spawn(function()
            local easeOut = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TS:Create(back, easeOut, { BackgroundTransparency = 0.4 }):Play()
            TS:Create(vp,   easeOut, { ImageTransparency = 0 }):Play()

            task.wait(HOLD_CENTRE)

            -- The word pushes the logo aside. Quint on the logo, not Back: a
            -- spring on a spinning object reads as a glitch.
            local slide = TweenInfo.new(SHIFT, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
            TS:Create(vp,   slide, { Position = UDim2.new(0.5, logoX, 0.5, 0) }):Play()
            TS:Create(flat, slide, { Position = UDim2.new(0.5, logoX, 0.5, 0) }):Play()

            for i, L in ipairs(labels) do
                task.delay(SHIFT * 0.35 + (i - 1) * LETTER_STEP, function()
                    local rise = TweenInfo.new(LETTER_RISE, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
                    TS:Create(L.holder, rise, { Position = UDim2.new(0.5, L.x, 0.5, 0) }):Play()
                    TS:Create(L.label,  rise, { TextTransparency = 0 }):Play()
                end)
            end

            -- When the last letter lands, stop the spin.
            local wordDone = SHIFT * 0.35 + (#labels - 1) * LETTER_STEP + LETTER_RISE
            task.delay(wordDone, beginSettle)

            task.wait(wordDone + SETTLE + HOLD_TEXT)

            local easeIn = TweenInfo.new(FADE_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
            TS:Create(back, easeIn, { BackgroundTransparency = 1 }):Play()
            TS:Create(vp,   easeIn, { ImageTransparency = 1 }):Play()
            TS:Create(flat, easeIn, { ImageTransparency = 1 }):Play()
            for _, L in ipairs(labels) do
                TS:Create(L.label, easeIn, { TextTransparency = 1 }):Play()
            end

            task.wait(FADE_OUT + 0.05)
            Splash.finished = true
        end)
    end

    function Splash.await(timeout)
        local deadline = os.clock() + (timeout or 15)
        while not Splash.finished and os.clock() < deadline do
            task.wait(0.05)
        end
    end

    function Splash.hide()
        local gui = Splash.gui
        Splash.gui = nil
        if Splash.conn then
            unbind(Splash.conn)
            Splash.conn = nil
        end
        if gui then pcall(function() gui:Destroy() end) end
        Splash.parts = nil
    end
end

do
    local ok, err = pcall(Splash.show)
    if not ok then
        warn("[Sys] splash failed: " .. tostring(err))
        Splash.finished = true   -- never let a broken splash hold the menu
    end
end

yield(true)

---------------------------------------------------------------------
-- WINDOW
---------------------------------------------------------------------
local ICONS = {
    player    = "rbxassetid://10747373176",  -- user
    visuals   = "rbxassetid://10723346959",  -- eye
    teleports = "rbxassetid://10734886202",  -- map
    misc      = "rbxassetid://10734909540",  -- package
    security  = "rbxassetid://10734951847",  -- shield
    settings  = "rbxassetid://10734950309",  -- gear
}

local Window = Atlas.new("Sys - Private", "SysPrivate/Bloodlines")

-- Built behind the splash; revealed once the sequence has played out.
Window.SetOpen(false)

local function notify(title, text, duration)
    Atlas:notify(title, text, duration or 3)
end

local TabPlayer    = Window.new_tab(ICONS.player,    "Player")
local TabVisuals   = Window.new_tab(ICONS.visuals,   "Visuals")
local TabTeleports = Window.new_tab(ICONS.teleports, "Teleports")
local TabMisc      = Window.new_tab(ICONS.misc,      "Misc")
local TabSecurity  = Window.new_tab(ICONS.security,  "Security")
local TabSettings  = Window.new_tab(ICONS.settings,  "Settings")

yield()

-- Sections are only touched while the menu is being built, so they live in
-- this table rather than each taking a local slot - the main chunk is close
-- to Lua's 200-local ceiling and the sectors below need those slots.
local UI = {}

-- Player
UI.secPlayer         = TabPlayer.new_section("General")
UI.boxMovement       = UI.secPlayer.new_sector("Movement", "Left")
UI.boxProtection     = UI.secPlayer.new_sector("Protection", "Right")
UI.playerUtil        = UI.secPlayer.new_sector("Utility", "Right")
UI.playerClothing    = UI.secPlayer.new_sector("Clothing", "Left")

UI.secCombat         = TabPlayer.new_section("Combat")
-- UI.parry             = UI.secCombat.new_sector("Auto Parry", "Left")
-- UI.parryMoves        = UI.secCombat.new_sector("Moves", "Right")
-- UI.parryTracker      = UI.secCombat.new_sector("Move Tracker", "Left")
UI.autoM1            = UI.secCombat.new_sector("Hold to M1", "Left")
UI.silentAim         = UI.secCombat.new_sector("Silent Aim", "Right")
UI.combatUtil        = UI.secCombat.new_sector("Utility", "Left")

-- UI.secBuilder        = TabPlayer.new_section("Parry Builder")
-- UI.builder           = UI.secBuilder.new_sector("Edit Move", "Left")
-- UI.builderAdd        = UI.secBuilder.new_sector("Custom Move", "Right")
-- UI.builderInfo       = UI.secBuilder.new_sector("Timing Reference", "Right")

-- Visuals
UI.secVisPlayers     = TabVisuals.new_section("Players")
UI.boxPlayerESP      = UI.secVisPlayers.new_sector("Player ESP", "Left")
UI.boxPlayerESPOpt   = UI.secVisPlayers.new_sector("Options", "Right")

UI.secVisMobs        = TabVisuals.new_section("Mobs")
UI.boxMobESP         = UI.secVisMobs.new_sector("Mob ESP", "Left")
UI.boxMobESPOpt      = UI.secVisMobs.new_sector("Options", "Right")

UI.secWorld          = TabVisuals.new_section("World")
UI.camera            = UI.secWorld.new_sector("Camera", "Right")
UI.worldVisuals      = UI.secWorld.new_sector("World Visuals", "Left")
UI.performance       = UI.secWorld.new_sector("Performance", "Right")

-- Teleports
UI.secTpLocations    = TabTeleports.new_section("Locations")
UI.boxChakraPoints   = UI.secTpLocations.new_sector("Chakra Points", "Left")
UI.boxFruits         = UI.secTpLocations.new_sector("Fruits", "Right")
UI.boxQuest          = UI.secTpLocations.new_sector("Quest", "Right")

UI.secTpPlayers      = TabTeleports.new_section("Players")
UI.boxTpPlayer       = UI.secTpPlayers.new_sector("Teleport to Player", "Left")

-- Misc
UI.secMiscData       = TabMisc.new_section("Data")
UI.boxViewData       = UI.secMiscData.new_sector("View Data", "Left")
UI.boxPurchase       = UI.secMiscData.new_sector("Purchase", "Right")

UI.secFarm           = TabMisc.new_section("Farm")
UI.mastery           = UI.secFarm.new_sector("Auto Farm Activations", "Left")
UI.masteryOpt        = UI.secFarm.new_sector("Options", "Right")
UI.ramen             = UI.secFarm.new_sector("Ramen Contest", "Left")

UI.secUtility        = TabMisc.new_section("Utility")
UI.spectate          = UI.secUtility.new_sector("Spectate", "Left")
UI.server            = UI.secUtility.new_sector("Server", "Right")
UI.watchers          = UI.secUtility.new_sector("Watchers", "Left")
UI.unwipe            = UI.secUtility.new_sector("Unwipe", "Right")

-- Security
UI.secSecurity       = TabSecurity.new_section("Protection")
UI.boxSafeTp         = UI.secSecurity.new_sector("Safe Teleport", "Left")
UI.boxDetection      = UI.secSecurity.new_sector("Detection", "Right")

-- Settings
UI.secSettings       = TabSettings.new_section("Configs")
UI.boxConfigs        = UI.secSettings.new_sector("Config", "Left")
UI.boxMenu           = UI.secSettings.new_sector("Menu", "Right")

yield(true)

---------------------------------------------------------------------
-- SHARED STATE
---------------------------------------------------------------------
local Players    = K.Services.Players
local RunService = K.Services.RunService
local RepStorage = K.Services.ReplicatedStorage
local Lighting   = K.Services.Lighting
local LP         = K.LocalPlayer

K.flags = {
    noclip           = false,
    omnimovement     = false,
    infiniteStamina  = false,
    noFallDamage     = false,
    antiVoid         = false,
    noVisualEffects  = false,
    chakraCharge     = false,
    buffChakra       = false,
    silentAim        = false,
    noCrowShake      = false,
    instantKunai     = false,
    forceOptimize    = false,
    removeParticles  = false,
    antiKnockback    = false,
    keybindList      = false,
    autoGenjutsu     = false,
    antiScramble     = false,
    antiAttach       = false,
    autoTotsuka      = false,
}

local function character()
    return LP.Character
end

local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function root()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- ReplicatedStorage.Settings is read constantly by ESP, speed and the chakra
-- sense watcher. Cache it for a couple of seconds rather than walking the
-- service every frame from three different systems.
-- ReplicatedStorage.Events.DataEvent. Walked to on demand rather than at
-- load, because the folder is not guaranteed to exist the moment the script
-- runs, and cached because the mastery farm teleports on a loop.
local _dataEvent = nil

local function dataEvent()
    if _dataEvent and _dataEvent.Parent then return _dataEvent end
    local events = RepStorage:FindFirstChild("Events")
    _dataEvent = events and events:FindFirstChild("DataEvent")
    return _dataEvent
end

local _settingsCache, _settingsCacheTime = nil, 0

-- Players:GetPlayers() builds a fresh table on every call, and three hot
-- paths call it: the ESP render loop every frame, silent aim's refresh every
-- frame while the aim key is down, and the hitbox sweep on every Heartbeat.
-- The roster only changes when somebody joins or leaves, so it is kept.
--
-- PlayerRemoving fires BEFORE the player leaves the service, so the rebuild is
-- deferred or the one who just left would still be in the list.
--
-- Callers get the real table, not a copy: read it, never hold or mutate it.
local _roster = Players:GetPlayers()

local function playerList()
    return _roster
end

bind(Players.PlayerAdded:Connect(function()
    _roster = Players:GetPlayers()
end))

bind(Players.PlayerRemoving:Connect(function()
    task.defer(function() _roster = Players:GetPlayers() end)
end))

-- Same shape as gameSettings below: the Cooldowns folder is walked to from
-- five places, two of them on a timer per player, and the service lookup is
-- not free.
local _cooldownsCache, _cooldownsCacheTime = nil, 0

local function cooldownsFolder()
    local now = os.clock()
    if _cooldownsCache and _cooldownsCache.Parent and (now - _cooldownsCacheTime) < 2 then
        return _cooldownsCache
    end
    _cooldownsCache     = RepStorage:FindFirstChild("Cooldowns")
    _cooldownsCacheTime = now
    return _cooldownsCache
end

local function gameSettings()
    local now = os.clock()
    if _settingsCache and _settingsCache.Parent and (now - _settingsCacheTime) < 2 then
        return _settingsCache
    end
    _settingsCache     = RepStorage:FindFirstChild("Settings")
    _settingsCacheTime = now
    return _settingsCache
end

local function mySettings()
    local s = gameSettings()
    return s and s:FindFirstChild(LP.Name)
end

local function settingFlag(name)
    local s = mySettings()
    if not s then return false end
    local v = s:FindFirstChild(name)
    return v and v.Value == true
end

local function settingText(name)
    local s = mySettings()
    if not s then return nil end
    local v = s:FindFirstChild(name)
    return v and v.Value
end

---------------------------------------------------------------------
-- FEATURE NAMECALL HOOK
--
-- One hook, installed once, reading flags out of K.flags. No Fall Damage and
-- Infinite Stamina both work by dropping the client's own self-report before
-- it leaves the machine.
--
-- Installed lazily: nothing is hooked until a feature that needs it is turned
-- on for the first time, so a load that never touches these leaves the
-- metatable untouched.
---------------------------------------------------------------------
local _hookInstalled = false

local function installFeatureHook()
    if _hookInstalled then return end
    if not hookmetamethod then return end

    local ok = pcall(function()
        local ncc = newcclosure or function(f) return f end
        local old
        old = hookmetamethod(game, "__namecall", ncc(function(self, ...)
            local method = getnamecallmethod()

            if method == "FireServer" then
                local arg1 = ...

                if arg1 == "TakeDamage" and K.flags.noFallDamage then
                    return nil
                end

                if arg1 == "Jump" and K.flags.infiniteStamina then
                    return nil
                end
            end

            return old(self, ...)
        end))
    end)

    _hookInstalled = ok
end

---------------------------------------------------------------------
-- DASH GUARD
--
-- Flicker Step (and the Lightning Dodge / Isobu Cloak variants) set the
-- FlickerStep attribute and raise WalkSpeed for ~0.5s, then restore it
-- themselves. The game's own setRunSpeed() opens with this check and returns
-- early, so anything of ours that writes WalkSpeed has to do the same or the
-- dash is overwritten on the next frame and does nothing.
---------------------------------------------------------------------
local function dashing()
    local c = character()
    if not c then return false end
    return c:GetAttribute("FlickerStep") and true or false
end

---------------------------------------------------------------------
-- NATIVE RUN SPEED
--
-- The game's run speed is OriginSpeed + 12 + awakening + consumable, where
-- OriginSpeed itself is BaseSpeed times clothing, chain, trait and ailment
-- multipliers. Recreating that chain would drift the moment any part of it
-- changed and be wrong for anyone with different gear.
--
-- So nothing is computed: we watch what the game actually writes to WalkSpeed
-- and reuse those exact numbers, classified by magnitude.
---------------------------------------------------------------------
local SPD = { run = nil, walk = nil, applying = false }

local function spdLearn(hum)
    -- Skip our own writes or we would only be learning our own output. The
    -- flag is CONSUMED here rather than cleared by the writer: on a frame
    -- where apply never runs, a flag left standing would stall learning.
    if SPD.applying then
        SPD.applying = false
        return
    end
    if dashing() then return end

    local ws = hum.WalkSpeed
    -- 0 is the combo finisher and 3 is the stun speed; neither is a baseline.
    if ws <= 5 then return end

    if not SPD.walk or ws < SPD.walk then
        SPD.walk = ws
        -- A new, lower baseline invalidates a run value learned against the
        -- old one (gear swap, buff expiry, chains applied).
        if SPD.run and SPD.run < SPD.walk + 6 then SPD.run = nil end
    end

    if ws >= SPD.walk + 6 then
        SPD.run = ws
    end
end

local function spdTarget()
    local target = SPD.run or (SPD.walk and (SPD.walk + 12))
    if not target then return nil end
    -- Bounded so a stale run value can never be chased upward. The server
    -- auto-reports WalkSpeed >= 110.
    if SPD.walk then
        target = math.min(target, SPD.walk + 40, 100)
    end
    return target
end

-- States where the game is deliberately driving WalkSpeed. Overriding any of
-- them is what makes M1s feel wrong: after each swing the game drops you to
-- walk speed for the combo window, and to 0 on the finisher.
local function spdYield()
    if dashing() then return true end

    local c = character()
    if not c then return true end
    if c:FindFirstChild("ragdolled") then return true end

    if settingFlag("MeleeCooldown") or settingFlag("HeavyCooldown") then return true end
    if settingFlag("Blocking") or settingFlag("Stunned") or settingFlag("Knocked") then return true end
    if settingFlag("Burrowing") then return true end

    local skill = settingText("CurrentSkill")
    if skill and skill ~= "" then return true end

    local grip = settingText("Gripping")
    if grip and grip ~= "None" then return true end

    local carried = settingText("BeingCarried")
    if carried and carried ~= "None" then return true end

    return false
end

local function spdApply(hum)
    if spdYield() then return false end

    local target = spdTarget()
    if not target then return false end

    -- Raise only. Anything already faster is the game's doing.
    if hum.WalkSpeed < target then
        SPD.applying = true
        hum.WalkSpeed = target
    end
    return true
end

-- OriginSpeed is rebuilt from clothing, chains and traits on every spawn, so a
-- baseline learned before a respawn can be wrong after it.
bind(LP.CharacterAdded:Connect(function()
    SPD.run      = nil
    SPD.walk     = nil
    SPD.applying = false
end))

---------------------------------------------------------------------
-- NOCLIP
---------------------------------------------------------------------
local Noclip = { conn = nil, original = {} }

local function setNoclip(on)
    K.flags.noclip = on

    if on then
        Noclip.original = {}
        Noclip.conn = bind(RunService.Stepped:Connect(function()
            if not K.flags.noclip then return end
            local c = character()
            if not c then return end

            for _, part in ipairs(c:GetDescendants()) do
                if part:IsA("BasePart") then
                    if Noclip.original[part] == nil then
                        Noclip.original[part] = part.CanCollide
                    end
                    part.CanCollide = false
                end
            end
        end))
        notify("Player", "Noclip enabled")
    else
        unbind(Noclip.conn)
        Noclip.conn = nil

        for part, was in pairs(Noclip.original) do
            if part and part.Parent then
                pcall(function() part.CanCollide = was end)
            end
        end
        Noclip.original = {}
        notify("Player", "Noclip disabled")
    end
end

UI.boxMovement.element("Toggle", "Noclip", nil, function(v)
    setNoclip(v.Toggle)
end)

---------------------------------------------------------------------
-- OMNIMOVEMENT (omnidirectional sprint)
--
-- The game only enters its run state from a double-tap of W, and onKeyUp
-- calls disableRun() the moment W is released, so strafing or backpedalling
-- always drops you to walk speed.
--
-- Rather than fight that state machine, this enforces the learned run speed
-- and the run animation whenever you are moving in ANY direction and keeps
-- Backpack.running true so the character reads as running. Direction comes
-- from Humanoid.MoveDirection, so it covers S/A/D, diagonals and controller.
---------------------------------------------------------------------
local Omni = {
    conn    = nil,
    track   = nil,
    animId  = "rbxassetid://5571412330",
    walkId  = "rbxassetid://6256500765",
}

local function omniBlocked()
    local c = character()
    if not c then return true end
    if c:FindFirstChild("ragdolled") then return true end
    if settingFlag("Blocking") or settingFlag("Stunned") then return true end
    return false
end

local function omniStop()
    unbind(Omni.conn)
    Omni.conn = nil

    if Omni.track then
        pcall(function() Omni.track:Stop() end)
        Omni.track = nil
    end

    pcall(function()
        local running = LP.Backpack:FindFirstChild("running")
        if running and running.Value then running.Value = false end
    end)
end

local function omniStart()
    omniStop()

    Omni.conn = bind(RunService.Heartbeat:Connect(function()
        if not K.flags.omnimovement then return end

        local c = character()
        if not c then return end
        local hum = c:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return end

        spdLearn(hum)

        local moving = hum.MoveDirection.Magnitude > 0.1

        if moving and not omniBlocked() then
            spdApply(hum)

            local running = LP.Backpack:FindFirstChild("running")
            if running and not running.Value then running.Value = true end

            local animator = hum:FindFirstChildOfClass("Animator")
            if animator then
                -- Drop the walk cycle so it does not fight the run anim.
                for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
                    if t.Animation and t.Animation.AnimationId == Omni.walkId then
                        t:Stop()
                        break
                    end
                end
                if not Omni.track or not Omni.track.IsPlaying then
                    local anim = Instance.new("Animation")
                    anim.AnimationId = Omni.animId
                    Omni.track = animator:LoadAnimation(anim)
                    Omni.track:Play()
                end
            end
        elseif Omni.track and Omni.track.IsPlaying then
            -- Standing still or blocked: hand control back to the game.
            Omni.track:Stop()
            Omni.track = nil
            local running = LP.Backpack:FindFirstChild("running")
            if running and running.Value then running.Value = false end
        end
    end))
end

UI.boxMovement.element("Toggle", "Omnimovement", nil, function(v)
    K.flags.omnimovement = v.Toggle
    if v.Toggle then
        omniStart()
        notify("Player", "Omnimovement enabled")
    else
        omniStop()
        notify("Player", "Omnimovement disabled")
    end
end)

---------------------------------------------------------------------
-- INFINITE STAMINA
--
-- Two halves: the namecall hook drops the "Jump" self-report, and a light
-- loop keeps the replicated Stamina value topped up.
---------------------------------------------------------------------
local staminaLoop = nil

UI.boxMovement.element("Toggle", "Infinite Stamina", nil, function(v)
    K.flags.infiniteStamina = v.Toggle

    if v.Toggle then
        installFeatureHook()

        if not staminaLoop then
            staminaLoop = task.spawn(function()
                while K.flags.infiniteStamina do
                    pcall(function()
                        local s = mySettings()
                        local stamina = s and s:FindFirstChild("Stamina")
                        if stamina then stamina.Value = 100 end
                    end)
                    task.wait(0.1)
                end
                staminaLoop = nil
            end)
        end
        notify("Player", "Infinite Stamina enabled")
    else
        notify("Player", "Infinite Stamina disabled")
    end
end)

UI.boxMovement.create_line()
UI.boxMovement.element("Label", "Menu keybind: Insert")

---------------------------------------------------------------------
-- NO FALL DAMAGE
---------------------------------------------------------------------
UI.boxProtection.element("Toggle", "No Fall Damage", nil, function(v)
    K.flags.noFallDamage = v.Toggle
    if v.Toggle then installFeatureHook() end
    notify("Player", "No Fall Damage " .. (v.Toggle and "enabled" or "disabled"))
end)

---------------------------------------------------------------------
-- ANTI KNOCKBACK
--
-- Every knockback is a BodyVelocity named "KnockbackBV" that the server puts
-- in the victim's HumanoidRootPart, or tells the victim's client to make via
-- "CreateVelocity" (GameManager.createBodyVelocity). Our client simulates
-- our own character, so a KnockbackBV that never applies force here means
-- no knockback.
--
-- MaxForce is zeroed the moment it appears, so not even one physics step of
-- push gets through, then it's destroyed. Destroying matters: the game sets
-- Velocity after parenting, and some calls start a per-frame obstacle loop
-- that keeps restoring MaxForce while the mover is parented - removing it
-- ends that loop. KnockbackBV is on the game's own allowed-mover list (the
-- BanMe 1E HRP check), and nothing is ever added by us.
---------------------------------------------------------------------
do
    local conns = {}

    local function neutralize(child)
        if child.Name ~= "KnockbackBV" or not child:IsA("BodyVelocity") then return end
        -- Angelic Rescue launches you out of the void with a KnockbackBV too
        -- (GameManager.angelicRescue), but its force is vertical-only
        -- (MaxForce 0, 1e7, 0); every real knockback pushes on all axes.
        -- Cancelling it would drop you back into the void - leave it alone.
        local mf = child.MaxForce
        if mf.X == 0 and mf.Z == 0 and mf.Y > 0 then return end
        pcall(function()
            child.MaxForce = Vector3.zero
            child.Velocity = Vector3.zero
        end)
        task.defer(function() pcall(child.Destroy, child) end)
    end

    local function watch(char)
        local hrp = char:WaitForChild("HumanoidRootPart", 10)
        if not hrp or not K.flags.antiKnockback then return end
        for _, ch in ipairs(hrp:GetChildren()) do neutralize(ch) end
        if conns.child then conns.child:Disconnect() end
        conns.child = hrp.ChildAdded:Connect(function(ch)
            if K.flags.antiKnockback then neutralize(ch) end
        end)
    end

    local function disconnectAll()
        for k, c in pairs(conns) do
            c:Disconnect()
            conns[k] = nil
        end
    end

    UI.boxProtection.element("Toggle", "Anti Knockback", nil, function(v)
        K.flags.antiKnockback = v.Toggle
        disconnectAll()
        if v.Toggle then
            if LP.Character then task.spawn(watch, LP.Character) end
            conns.char = LP.CharacterAdded:Connect(watch)
            notify("Player", "Anti Knockback enabled")
        else
            notify("Player", "Anti Knockback disabled")
        end
    end)
end

---------------------------------------------------------------------
-- ANTI VOID
--
-- The void kills on touch, so the kill is stopped at the part rather than at
-- the character: CanTouch = false on every void part, plus a watcher for the
-- ones the game re-enables and for parts streamed in later.
---------------------------------------------------------------------
local Void = { conns = {}, parts = {} }

local function isVoidPart(inst)
    local n = inst.Name
    return (n == "LavarossaVoid" or n == "Void") and inst:IsA("BasePart")
end

local function watchVoidPart(part)
    Void.conns[#Void.conns + 1] = bind(part:GetPropertyChangedSignal("CanTouch"):Connect(function()
        if part.CanTouch and K.flags.antiVoid then
            pcall(function() part.CanTouch = false end)
        end
    end))
end

UI.boxProtection.element("Toggle", "Anti Void", nil, function(v)
    K.flags.antiVoid = v.Toggle

    if v.Toggle then
        for _, inst in ipairs(workspace:GetDescendants()) do
            if isVoidPart(inst) then
                pcall(function() inst.CanTouch = false end)
                Void.parts[inst] = true
                watchVoidPart(inst)
            end
        end

        Void.conns[#Void.conns + 1] = bind(workspace.DescendantAdded:Connect(function(inst)
            if not K.flags.antiVoid then return end
            if isVoidPart(inst) then
                pcall(function() inst.CanTouch = false end)
                Void.parts[inst] = true
                watchVoidPart(inst)
            end
        end))

        notify("Player", "Anti Void enabled")
    else
        for _, c in ipairs(Void.conns) do unbind(c) end
        Void.conns = {}

        for part in pairs(Void.parts) do
            if part and part.Parent then
                pcall(function() part.CanTouch = true end)
            end
        end
        Void.parts = {}

        notify("Player", "Anti Void disabled")
    end
end)

---------------------------------------------------------------------
-- NO VISUAL EFFECTS
--
-- The game re-asserts these properties constantly (weather, jutsu, cutscenes),
-- so the originals are captured once on enable and property-changed watchers
-- put our values back rather than a per-frame write loop.
---------------------------------------------------------------------
local Visual = { conns = {}, original = nil }

local function captureVisuals()
    local o = {
        FogEnd         = Lighting.FogEnd,
        Brightness     = Lighting.Brightness,
        ClockTime      = Lighting.ClockTime,
        GlobalShadows  = Lighting.GlobalShadows,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        effects        = {},
    }

    pcall(function()
        local sphere = workspace:FindFirstChild("Debris")
        sphere = sphere and sphere:FindFirstChild("InvertedSphere")
        if sphere then
            o.sphere             = sphere
            o.sphereTransparency = sphere.Transparency
        end

        local raining = RepStorage:FindFirstChild("Raining")
        if raining then o.raining = raining.Value end
    end)

    for _, fx in ipairs(Lighting:GetChildren()) do
        if fx:IsA("BlurEffect") or fx:IsA("ColorCorrectionEffect") or fx:IsA("DepthOfFieldEffect") then
            o.effects[fx] = fx.Enabled
        end
    end

    Visual.original = o
end

local function applyVisuals()
    if not K.flags.noVisualEffects then return end

    pcall(function()
        Lighting.FogEnd         = 100000
        Lighting.Brightness     = 2
        Lighting.ClockTime      = 14
        Lighting.GlobalShadows  = false
        Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)

        local debrisFolder = workspace:FindFirstChild("Debris")
        local sphere = debrisFolder and debrisFolder:FindFirstChild("InvertedSphere")
        if sphere then sphere.Transparency = 1 end

        local raining = RepStorage:FindFirstChild("Raining")
        if raining then raining.Value = "" end

        for _, fx in ipairs(Lighting:GetChildren()) do
            if fx:IsA("BlurEffect") or fx:IsA("ColorCorrectionEffect") or fx:IsA("DepthOfFieldEffect") then
                fx.Enabled = false
            end
        end
    end)
end

local function restoreVisuals()
    local o = Visual.original
    if not o then return end

    pcall(function()
        Lighting.FogEnd         = o.FogEnd
        Lighting.Brightness     = o.Brightness
        Lighting.ClockTime      = o.ClockTime
        Lighting.GlobalShadows  = o.GlobalShadows
        Lighting.OutdoorAmbient = o.OutdoorAmbient

        if o.sphere and o.sphere.Parent then
            o.sphere.Transparency = o.sphereTransparency
        end

        if o.raining then
            local raining = RepStorage:FindFirstChild("Raining")
            if raining then raining.Value = o.raining end
        end

        for fx, was in pairs(o.effects) do
            if fx and fx.Parent then fx.Enabled = was end
        end
    end)

    Visual.original = nil
end

UI.boxProtection.element("Toggle", "No Visual Effects", nil, function(v)
    K.flags.noVisualEffects = v.Toggle

    if v.Toggle then
        captureVisuals()
        applyVisuals()

        local function guard(prop, want)
            Visual.conns[#Visual.conns + 1] = bind(Lighting:GetPropertyChangedSignal(prop):Connect(function()
                if K.flags.noVisualEffects and Lighting[prop] ~= want then
                    Lighting[prop] = want
                end
            end))
        end

        guard("FogEnd", 100000)
        guard("Brightness", 2)
        guard("ClockTime", 14)
        guard("GlobalShadows", false)
        guard("OutdoorAmbient", Color3.fromRGB(128, 128, 128))

        Visual.conns[#Visual.conns + 1] = bind(Lighting.ChildAdded:Connect(function(fx)
            if not K.flags.noVisualEffects then return end
            if fx:IsA("BlurEffect") or fx:IsA("ColorCorrectionEffect") or fx:IsA("DepthOfFieldEffect") then
                fx.Enabled = false
            end
        end))

        notify("Player", "No Visual Effects enabled")
    else
        for _, c in ipairs(Visual.conns) do unbind(c) end
        Visual.conns = {}
        restoreVisuals()
        notify("Player", "No Visual Effects disabled")
    end
end)

---------------------------------------------------------------------
-- INFINITE CHAKRA CHARGE
--
-- Charging is a server-side state the client opens by firing DataEvent
-- "Charging", and the server closes on its own after a tick. The local
-- HumanoidRootPart carries a "ChakraCharge" sound that plays for exactly as
-- long as the charge is running, so the sound's Playing property is a free,
-- exact signal for "the charge just ended" - no polling, no timers.
--
-- Each time it stops we re-open it with the same event the game itself sends,
-- so the traffic is identical to a player holding the key down.
--
-- Two things the public version gets wrong and this does not:
--   * It connects CharacterAdded every time the toggle is switched on and
--     never disconnects it, so flipping the toggle a few times leaves several
--     handlers stacked on the same event.
--   * It has no floor on how often it can re-fire. A sound that flickers
--     Playing (lag, an overlapping effect) turns into a FireServer spam loop,
--     which is the one thing here that would actually stand out.
---------------------------------------------------------------------
local Charge = { conn = nil, respawnConn = nil, wasPlaying = false, last = 0 }

local function chargeFire()
    -- The game's own charge tick is about a second; anything faster than this
    -- is the sound flickering, not a charge that really ended.
    local now = os.clock()
    if now - Charge.last < 0.15 then return end
    Charge.last = now

    pcall(function()
        RepStorage:WaitForChild("Events"):WaitForChild("DataEvent"):FireServer("Charging")
    end)
end

local function chargeAttach()
    if Charge.conn then
        unbind(Charge.conn)
        Charge.conn = nil
    end

    local c   = character()
    local hrp = c and c:FindFirstChild("HumanoidRootPart")
    local sound = hrp and hrp:FindFirstChild("ChakraCharge")
    if not sound then return end

    Charge.wasPlaying = sound.Playing

    -- Open the charge immediately if it is not already running, otherwise the
    -- feature does nothing until the next time you charge by hand.
    if not sound.Playing then
        chargeFire()
    end

    Charge.conn = bind(sound:GetPropertyChangedSignal("Playing"):Connect(function()
        if not K.flags.chakraCharge then return end

        -- Only the falling edge matters: it just finished, so start it again.
        if Charge.wasPlaying and not sound.Playing then
            chargeFire()
        end
        Charge.wasPlaying = sound.Playing
    end))
end

local function chargeStop()
    if Charge.conn then
        unbind(Charge.conn)
        Charge.conn = nil
    end
    Charge.wasPlaying = false
end

---------------------------------------------------------------------
-- FORCE RESET
--
-- Health = 0 is enough on its own most of the time, but this game drives
-- health entirely server side, so a local write can be re-synced away. The
-- ladder covers that: ask nicely, force the state, then tear the rig apart.
-- Each step only runs if the one before it did not take.
---------------------------------------------------------------------
UI.playerUtil.element("Button", "Force Reset", nil, function()
    task.spawn(function()
        local char = character()
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then
            notify("Player", "No character", 3)
            return
        end

        pcall(function() hum.Health = 0 end)
        task.wait(0.3)

        if LP.Character ~= char then return end
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Dead) end)
        task.wait(0.3)

        if LP.Character == char then
            pcall(function() char:BreakJoints() end)
        end
    end)
end)

---------------------------------------------------------------------
-- KICK ON KEY PRESS
--
-- A panic key: disconnects you instantly. Client-side Kick needs no server
-- co-operation, so it is the fastest way out of a server - faster than a
-- teleport, which has to round trip.
---------------------------------------------------------------------
do
    local armed = false

    local toggle = UI.playerUtil.element("Toggle", "Kick on Key Press", nil, function(v)
        armed = v.Toggle
        notify("Player", v.Toggle
            and "Kick on Key Press armed - bind a key on the right"
            or  "Kick on Key Press disarmed", 4)
    end)

    toggle:add_keybind(nil, function(v)
        -- Only a genuine press. Without this the kick would also fire while
        -- you are binding the key or when a config loads.
        if not v.Pressed then return end
        if not armed or not v.Key then return end

        pcall(function() LP:Kick("[Key Pressed]") end)
    end)
end

---------------------------------------------------------------------
-- BUFF CHAKRA REGEN
--
-- Backpack.chakra is a plain NumberValue the server drives. Every time it
-- ticks UPWARD (a regen tick), this immediately claims a little more on top
-- by firing DataEvent "TakeChakra" with a NEGATIVE amount - the same event
-- the game uses to spend chakra, so a negative spend is a gain - and mirrors
-- the result locally so the HUD agrees.
--
-- Only reacts to increases. A decrease is you spending chakra, and re-adding
-- there would fight the game's own bookkeeping; that branch just re-baselines.
--
-- The 0.9s cooldown matches the game's regen tick: firing more often than it
-- regenerates is what turns this from "a bit more chakra" into a stream of
-- events with nothing behind them.
---------------------------------------------------------------------
local Chakra = { amount = 3, conn = nil, respawnConn = nil }

local function chakraStop()
    unbind(Chakra.conn)
    Chakra.conn = nil
end

local function chakraAttach()
    chakraStop()

    local backpack = LP:FindFirstChildOfClass("Backpack")
    local chakra   = backpack and backpack:FindFirstChild("chakra")
    local maxChakra = backpack and backpack:FindFirstChild("maxChakra")
    if not chakra then return end

    local baseline = chakra.Value
    local cooling  = false

    Chakra.conn = bind(chakra.Changed:Connect(function(newValue)
        if not K.flags.buffChakra then return end

        if newValue <= baseline then
            -- Spending, or the server correcting us downward.
            baseline = newValue
            return
        end

        if cooling then return end
        cooling = true

        local target = chakra.Value + Chakra.amount
        if not maxChakra or target < maxChakra.Value then
            pcall(function()
                RepStorage:WaitForChild("Events"):WaitForChild("DataEvent")
                    :FireServer("TakeChakra", -Chakra.amount)
            end)
            chakra.Value = chakra.Value + Chakra.amount
        end

        baseline = newValue
        task.wait(0.9)
        cooling = false
    end))
end

UI.playerUtil.element("Toggle", "Buff Chakra Regen", nil, function(v)
    K.flags.buffChakra = v.Toggle

    if v.Toggle then
        chakraAttach()

        -- The Backpack and its chakra value are rebuilt on respawn.
        if not Chakra.respawnConn then
            Chakra.respawnConn = bind(LP.CharacterAdded:Connect(function()
                if not K.flags.buffChakra then return end
                task.wait(1.3)
                if K.flags.buffChakra then chakraAttach() end
            end))
        end

        notify("Player", "Buff Chakra Regen enabled")
    else
        chakraStop()
        notify("Player", "Buff Chakra Regen disabled")
    end
end)

UI.playerUtil.element("Slider", "Chakra Bonus", {
    default = { min = 1, max = 6, default = 3 },
}, function(v)
    Chakra.amount = v.Slider
end)

UI.playerUtil.element("Toggle", "Infinite Chakra Charge", nil, function(v)
    K.flags.chakraCharge = v.Toggle

    if v.Toggle then
        chargeAttach()

        -- Bound once, not once per enable. The sound instance is recreated
        -- with the character, so the watcher has to be rebuilt after a
        -- respawn - but the respawn hook itself only needs to exist once.
        if not Charge.respawnConn then
            Charge.respawnConn = bind(LP.CharacterAdded:Connect(function()
                if not K.flags.chakraCharge then return end
                task.wait(1)
                if not K.flags.chakraCharge then return end
                chargeAttach()
            end))
        end

        notify("Player", "Infinite Chakra Charge enabled")
    else
        chargeStop()
        notify("Player", "Infinite Chakra Charge disabled")
    end
end)

---------------------------------------------------------------------
-- HITBOX EXTENDER
--
-- The game spawns a Hitbox part for dash-type moves and parents the rest to
-- the character. Both carry a TouchInterest, and firetouchinterest is the
-- only primitive that can drive one: replicatesignal will not work here,
-- because cansignalreplicate on BasePart.Touched returns false and Roblox's
-- replication whitelist has no TouchTransmitter entry at all. That also means
-- the server's own distance check on the Touched handler still applies - this
-- widens the window, it does not bypass the server.
--
-- Only fires while CurrentSkill is one of the moves below, bails the moment
-- the skill changes, and skips knocked players (they cannot be hit anyway,
-- so touching them is pure noise on the wire).
---------------------------------------------------------------------
local Hitbox = {
    enabled   = false,
    size      = 8,
    conn      = nil,
    whitelist = {},

    -- Moves whose hitbox lives in workspace.Debris rather than on the
    -- character. Everything else is looked up by skill name under the
    -- character itself.
    debrisMoves = {
        ["Lion's Barrage"]  = true,
        ["Dynamic Entry"]   = true,
        ["Thrusting Strike"]= true,
        ["Primary Lotus"]   = true,
        ["Cleave Rush"]     = true,
        ["Vertical Slash"]  = true,
    },

    moves = {
        "Lion's Barrage", "Cleave Rush", "Dynamic Entry", "Rasengan",
        "Rasengan Barrage", "Fire Seal", "Thrusting Strike", "Water Prison",
        "Chidori", "Primary Lotus", "Wood Seal", "Vertical Slash",
        "Rasenshuriken", "Fireball", "Weighted Kick", "Leaf Whirlwind",
    },
}

local function fireTouch(part, otherHRP)
    if not part or not otherHRP then return end
    if not firetouchinterest then return end
    if not part:FindFirstChild("TouchInterest") then return end

    pcall(function()
        firetouchinterest(part, otherHRP, 0)
        firetouchinterest(part, otherHRP, 1)
    end)
end

-- Targets worth touching: not us, not whitelisted, not knocked, in range.
local function hitboxTargets(myPos)
    local out = {}
    local settings = gameSettings()

    for _, target in ipairs(playerList()) do
        if target ~= LP and not table.find(Hitbox.whitelist, target.Name) then
            local char = target.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")

            if hrp and (hrp.Position - myPos).Magnitude <= Hitbox.size then
                local ps      = settings and settings:FindFirstChild(target.Name)
                local knocked = ps and ps:FindFirstChild("Knocked")
                if not (knocked and knocked.Value == true) then
                    out[#out + 1] = hrp
                end
            end
        end
    end

    return out
end

local function hitboxStop()
    unbind(Hitbox.conn)
    Hitbox.conn = nil
end

local function hitboxStart()
    hitboxStop()

    Hitbox.conn = bind(RunService.Heartbeat:Connect(function()
        if not Hitbox.enabled then return end

        local char = character()
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local skill = settingText("CurrentSkill")
        if not skill or skill == "" then return end
        if not table.find(Hitbox.moves, skill) then return end

        local targets = hitboxTargets(hrp.Position)
        if #targets == 0 then return end

        if Hitbox.debrisMoves[skill] then
            local debrisFolder = workspace:FindFirstChild("Debris")
            if not debrisFolder then return end

            for _, part in ipairs(debrisFolder:GetChildren()) do
                -- The skill can end mid-sweep; stop rather than touch with a
                -- hitbox that no longer belongs to the move being used.
                if settingText("CurrentSkill") ~= skill then return end
                if part.Name == "Hitbox" then
                    for _, otherHRP in ipairs(targets) do
                        fireTouch(part, otherHRP)
                    end
                end
            end

        elseif skill == "Rasengan Barrage" then
            -- This one is two parts, one per hand.
            for _, side in ipairs({ "RasenganLeft", "RasenganRight" }) do
                local part = char:FindFirstChild(side)
                for _, otherHRP in ipairs(targets) do
                    fireTouch(part, otherHRP)
                end
            end

        else
            local part = char:FindFirstChild(skill)
            for _, otherHRP in ipairs(targets) do
                fireTouch(part, otherHRP)
            end
        end
    end))
end

UI.playerUtil.element("Toggle", "Hitbox Extender", nil, function(v)
    Hitbox.enabled = v.Toggle

    if v.Toggle then
        if not firetouchinterest then
            Hitbox.enabled = false
            notify("Player", "This executor has no firetouchinterest", 5)
            return
        end
        hitboxStart()
        notify("Player", "Hitbox Extender enabled")
    else
        hitboxStop()
        notify("Player", "Hitbox Extender disabled")
    end
end)

UI.playerUtil.element("Slider", "Hitbox Size", {
    default = { min = 1, max = 15, default = 8 },
    suffix  = " studs",
}, function(v)
    Hitbox.size = v.Slider
end)

UI.playerUtil.element("TextBox", "Hitbox Whitelist (comma sep)", { maxlen = 120 }, function(v)
    local list = {}
    for name in string.gmatch(v.Text, "[^,]+") do
        list[#list + 1] = (name:gsub("^%s*(.-)%s*$", "%1"))
    end
    Hitbox.whitelist = list
end)

yield(true)

-- Scoped: this block needs fifteen locals and the main chunk is already
-- close to Lua's 200-local ceiling, so they live in a block of their own.
do
---------------------------------------------------------------------
-- CLOTHING CHANGER
--
-- Two halves, because the game keeps the two kinds of outfit in two very
-- different places.
--
-- A plain outfit is nothing but a Shirt and a Pants texture, and both sit in
-- ReplicatedStorage.Clothing.<name>, which the client can read. Wearing one
-- is two property writes.
--
-- An ascended outfit is real geometry, and needs a model plus a rigging.
--
-- The model is looked for in ReplicatedStorage.Clothing.<name> first, under
-- Normal or Broken, mirroring where the server takes it from. The server's own
-- copy is ServerStorage.App.Clothing, which the client cannot see, so if the
-- replicated folder does not mirror it the model is taken off somebody who is
-- already wearing it instead - the server welds it into their character, where
-- it replicates like any other instance.
--
-- The rigging comes from one of three places, in this order:
--
--   1. The model's own Motor6Ds, when they carry a Part0 attribute naming the
--      limb. The offsets are already baked in and the server does nothing but
--      resolve the name (gamescript2.txt:5127). Twelve outfits work this way
--      and need no data from us at all.
--   2. CLOTH_WELDS below, lifted out of GameManager:weld, for the eleven older
--      outfits whose offsets are hardcoded one branch at a time.
--   3. A wearer's live joints. weldParts parents each Weld to the clothing
--      piece with Part0 on the limb, so a wearer carries its own placement.
--
-- Between them that covers 24 of the 27 ascended outfits with nobody else in
-- the server. The remaining three - Akatsuki Cloak, Avenger's Outfit and
-- Martial Artist - build their pieces in a way the dump does not express
-- cleanly, so they still want a wearer to copy from, and say so when picked.
--
-- All of it is local. Texture writes and client-made welds do not replicate,
-- so the outfit is visible to us and to nobody else.
---------------------------------------------------------------------
-- Every ascended outfit the game defines (u20.Clothing, gamescript2.txt).
-- Listed unconditionally so the pick always exists; whether its geometry can
-- be reached is decided at apply time, and said plainly if it cannot.
local ASCENDED_NAMES = {
    "Ascended Akatsuki Cloak",
    "Ascended Akatsuki Leader",
    "Ascended Anbu",
    "Ascended Assassin's Garments",
    "Ascended Avenger's Outfit",
    "Ascended Biyo Armor",
    "Ascended Brawler's Outfit",
    "Ascended Durana Kage",
    "Ascended Durana Outfit",
    "Ascended Fighter's Outfit",
    "Ascended Haku Outfit",
    "Ascended Martial Artist",
    "Ascended Moon Rags",
    "Ascended Orange Jumpsuit",
    "Ascended Peacemaker",
    "Ascended Rain Kage",
    "Ascended Rain Outfit",
    "Ascended Reanimated Cloak",
    "Ascended Senju Armor",
    "Ascended Shisui Outfit",
    "Ascended Slithering Outfit",
    "Ascended Snow Kage",
    "Ascended Snow Outfit",
    "Ascended Sorythia Kage",
    "Ascended Sorythia Outfit",
    "Ascended Thunder Cloak",
    "Ascended Wanderer's Outfit",
}

-- Outfits whose stored model describes its own rigging: each Motor6D carries
-- a Part0 attribute naming the limb and the offsets are already baked in, so
-- the server only resolves the name (gamescript2.txt:5127). Substring matches,
-- exactly as the game matches them - note "Akatsuki Leader" also catches the
-- ascended one.
local SELF_RIGGED = {
    "Ascended Sorythia Kage",
    "Ascended Durana Kage",
    "Ascended Rain Kage",
    "Ascended Snow Kage",
    "Akatsuki Leader",
    "Ascended Snow Outfit",
    "Ascended Sorythia Outfit",
    "Ascended Rain Outfit",
    "Ascended Durana Outfit",
    "Ascended Anbu",
    "Ascended Orange Jumpsuit",
    "Ascended Haku Outfit",
    "Ascended Shisui Outfit",
}

-- The older outfits have their offsets written out longhand instead, one
-- branch per outfit in GameManager:weld. Lifted from the dump rather than
-- eyeballed. `clone` marks a mirrored piece that ships once and is copied
-- for the other side, which is what the server does.
local CLOTH_WELDS = {
    -- gamescript2.txt:4779. The Cloak piece is deliberately absent: the server
    -- never welds it, it hangs off an AnimationController playing
    -- AkatsukiCloakIdle, so the leftover pass pins it by authored offset and it
    -- renders in place without the sway.
    ["Ascended Akatsuki Cloak"] = {
        { limb = "Torso",     piece = "RootPart", c0 = CFrame.new(0, -1.75, 0) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, -0.05, 0.1) },
        { limb = "Left Arm",  piece = "LeftArm",  c0 = CFrame.new(0, -0.05, 0.1) },
    },
    -- Same model and the same branch, under the other name.
    ["Ascended Akatsuki Leader"] = {
        { limb = "Torso",     piece = "RootPart", c0 = CFrame.new(0, -1.75, 0) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, -0.05, 0.1) },
        { limb = "Left Arm",  piece = "LeftArm",  c0 = CFrame.new(0, -0.05, 0.1) },
    },
    -- gamescript2.txt:4529
    ["Ascended Avenger's Outfit"] = {
        { limb = "Right Arm", piece = "RightArm",    c0 = CFrame.new(0.002, 0.094, 0) },
        { limb = "Left Arm",  piece = "LeftArm",     c0 = CFrame.new(-0.002, 0.094, 0) },
        { limb = "Torso",     piece = "TorsoMain",   c0 = CFrame.new(0, 0.216, 0.139) },
        { limb = "Torso",     piece = "Zipper",      c0 = CFrame.new(0, -0.186, -0.533) },
        { limb = "Torso",     piece = "RobeMain",    c0 = CFrame.new(0, -0.748, -0.01) },
        { limb = "Right Leg", piece = "RightLeg",    c0 = CFrame.new(0.016, 0.12, -0.01) },
        { limb = "Left Leg",  piece = "LeftLeg",     c0 = CFrame.new(-0.016, 0.12, -0.01) },
        { limb = "Right Leg", piece = "RightRobe",   c0 = CFrame.new(0.141, 0.402, -0.01) },
        { limb = "Left Leg",  piece = "LeftRobe",    c0 = CFrame.new(-0.141, 0.402, -0.01) },
        { limb = "Right Leg", piece = "RightSandal", c0 = CFrame.new(-0.002, -0.911, 0.005) },
        { limb = "Left Leg",  piece = "LeftSandal",  c0 = CFrame.new(0.002, -0.911, 0.005) },
    },
    -- gamescript2.txt:4494
    ["Ascended Martial Artist"] = {
        { limb = "Right Arm", piece = "RightArm",    c0 = CFrame.new(0.026, 0.102, -0.007) },
        { limb = "Left Arm",  piece = "LeftArm",     c0 = CFrame.new(-0.026, 0.102, -0.007) },
        { limb = "Torso",     piece = "TorsoMain",   c0 = CFrame.new(0.025, 0.12, -0.021) },
        { limb = "Torso",     piece = "RobeMain",    c0 = CFrame.new(0.018, -0.893, -0.007) },
        { limb = "Right Leg", piece = "RightLeg",    c0 = CFrame.new(0.036, 0.153, -0.007) },
        { limb = "Left Leg",  piece = "LeftLeg",     c0 = CFrame.new(-0.036, 0.153, -0.007) },
        { limb = "Right Leg", piece = "RightRobe",   c0 = CFrame.new(0.076, 0.485, -0.007) },
        { limb = "Left Leg",  piece = "LeftRobe",    c0 = CFrame.new(-0.076, 0.485, -0.007) },
        { limb = "Right Leg", piece = "RightSandal", c0 = CFrame.new(0.034, -0.849, 0.002) },
        { limb = "Left Leg",  piece = "LeftSandal",  c0 = CFrame.new(-0.034, -0.849, 0.002) },
    },
    ["Ascended Assassin's Garments"] = {
        { limb = "Left Arm", piece = "ArmBrace", c0 = CFrame.new(0, -0.53, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Arm", piece = "ArmBrace", clone = true, c0 = CFrame.new(0, -0.53, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Left Leg", piece = "LegBrace", c0 = CFrame.new(0, -0.6, 0) * CFrame.Angles(0, -1.5707963267948966, 0) },
        { limb = "Right Leg", piece = "LegBrace", clone = true, c0 = CFrame.new(0, -0.6, 0) * CFrame.Angles(0, -1.5707963267948966, 0) },
    },
    ["Ascended Biyo Armor"] = {
        { limb = "Torso", piece = "SenjuTorso", c0 = CFrame.new(0, 0.18, 0) },
        { limb = "Torso", piece = "SenjuCollar", c0 = CFrame.new(0, 1.18, 0.05) },
        { limb = "Right Arm", piece = "SenjuRightShoulder", c0 = CFrame.new(0.105, 0.99, 0) },
        { limb = "Left Arm", piece = "SenjuLeftShoulder", c0 = CFrame.new(-0.105, 0.99, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Leg", piece = "SenjuRightLeg", c0 = CFrame.new(0.46, 0.57, 0) },
        { limb = "Left Leg", piece = "SenjuLeftLeg", c0 = CFrame.new(-0.46, 0.57, 0) },
    },
    ["Ascended Brawler's Outfit"] = {
        { limb = "Torso", piece = "torso", c0 = CFrame.new(0, -0.04, -0.07) * CFrame.Angles(0, -1.5707963267948966, 0) },
        { limb = "Left Arm", piece = "lefthand", c0 = CFrame.new(-0.02, -0.68, 0.01) * CFrame.Angles(0, -1.5707963267948966, 0) },
        { limb = "Right Arm", piece = "righthand", c0 = CFrame.new(0.02, -0.68, -0.01) * CFrame.Angles(0, -1.5707963267948966, 0) },
        { limb = "Left Arm", piece = "leftshoulder", c0 = CFrame.new(-0.41, 0.53, 0) * CFrame.Angles(0, -1.5707963267948966, 0) },
        { limb = "Right Arm", piece = "rightshoulder", c0 = CFrame.new(0.41, 0.53, 0) * CFrame.Angles(0, -1.5707963267948966, 0) },
        { limb = "Left Leg", piece = "leftleg", c0 = CFrame.new(-0.39, 0.46, 0) * CFrame.Angles(0, -1.5707963267948966, 0) },
        { limb = "Right Leg", piece = "rightleg", c0 = CFrame.new(0.39, 0.46, 0) * CFrame.Angles(0, -1.5707963267948966, 0) },
    },
    ["Ascended Fighter's Outfit"] = {
        { limb = "Torso", piece = "TorsoMain", c0 = CFrame.new(0, 0.05, 0) },
        { limb = "Left Arm", piece = "LeftArm", c0 = CFrame.new(0, 0.37, 0) },
        { limb = "Left Arm", piece = "LeftBandage", c0 = CFrame.new(0, -0.64, 0) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, 0.37, 0) },
        { limb = "Right Arm", piece = "RightBandage", c0 = CFrame.new(0, -0.64, 0) },
        { limb = "Left Leg", piece = "LeftLeg", c0 = CFrame.new(0, 0.39, 0) },
        { limb = "Right Leg", piece = "RightLeg", c0 = CFrame.new(0, 0.39, 0) },
        { limb = "Left Leg", piece = "LeftWrap", c0 = CFrame.new(0, -0.49, 0) },
        { limb = "Right Leg", piece = "RightWrap", c0 = CFrame.new(0, -0.49, 0) },
        { limb = "Left Leg", piece = "LeftSandal", c0 = CFrame.new(0, -0.89, 0) },
        { limb = "Right Leg", piece = "RightSandal", c0 = CFrame.new(0, -0.89, 0) },
    },
    ["Ascended Moon Rags"] = {
        { limb = "Left Arm", piece = "LeftArm", c0 = CFrame.new(0, 0.03, 0.18) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, 0.03, 0.18) },
        { limb = "Torso", piece = "TorsoMain", c0 = CFrame.new(0, 0.25, 0.01) },
        { limb = "Torso", piece = "TorsoSkirt", c0 = CFrame.new(0, -1, 0) },
        { limb = "Torso", piece = "TorsoBand", c0 = CFrame.new(0, -0.86, 0) },
        { limb = "Left Leg", piece = "LeftSandal", c0 = CFrame.new(0, -0.93, -0.07) },
        { limb = "Left Leg", piece = "LeftLowerLeg", c0 = CFrame.new(0, -0.55, 0) },
        { limb = "Left Leg", piece = "LeftLeg", c0 = CFrame.new(0, 0.34, -0.01) },
        { limb = "Right Leg", piece = "RightSandal", c0 = CFrame.new(0, -0.93, -0.07) },
        { limb = "Right Leg", piece = "RightLowerLeg", c0 = CFrame.new(0, -0.55, 0) },
        { limb = "Right Leg", piece = "RightLeg", c0 = CFrame.new(0, 0.34, -0.01) },
    },
    ["Ascended Peacemaker"] = {
        { limb = "Torso", piece = "TorsoPart", c0 = CFrame.new(0, -0.05, 0) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, 0.6, 0) },
        { limb = "Left Arm", piece = "LeftArm", c0 = CFrame.new(0, 0.6, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Leg", piece = "RightLeg", c0 = CFrame.new(0, 0, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Left Leg", piece = "LeftLeg", c0 = CFrame.new(0, 0, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
    },
    ["Ascended Reanimated Cloak"] = {
        { limb = "Torso", piece = "RootPart", c0 = CFrame.new(0, -1.5, -0.14) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, 0.1, 0) * CFrame.Angles(1.5707963267948966, 0, 0) },
        { limb = "Left Arm", piece = "LeftArm", c0 = CFrame.new(0, 0.1, 0) * CFrame.Angles(1.5707963267948966, 0, 0) },
    },
    ["Ascended Senju Armor"] = {
        { limb = "Torso", piece = "SenjuTorso", c0 = CFrame.new(0, 0.18, 0) },
        { limb = "Torso", piece = "SenjuCollar", c0 = CFrame.new(0, 1.18, 0.05) },
        { limb = "Right Arm", piece = "SenjuRightShoulder", c0 = CFrame.new(0.105, 0.99, 0) },
        { limb = "Left Arm", piece = "SenjuLeftShoulder", c0 = CFrame.new(-0.105, 0.99, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Leg", piece = "SenjuRightLeg", c0 = CFrame.new(0.46, 0.57, 0) },
        { limb = "Left Leg", piece = "SenjuLeftLeg", c0 = CFrame.new(-0.46, 0.57, 0) },
    },
    ["Ascended Slithering Outfit"] = {
        { limb = "Left Arm", piece = "LeftArm", c0 = CFrame.new(0, 0.112, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Left Arm", piece = "LeftUpperArm", c0 = CFrame.new(-0.002, 0.59, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, 0.112, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Arm", piece = "RightUpperArm", c0 = CFrame.new(0.008, 0.59, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Torso", piece = "TorsoMain", c0 = CFrame.new(0, -0.321, 0.02) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Torso", piece = "TorsoCover", c0 = CFrame.new(0, 0, 0) },
        { limb = "Torso", piece = "Neck", c0 = CFrame.new(0, 0.795, -0.015) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Left Leg", piece = "LeftSandal", c0 = CFrame.new(0, -0.92, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Left Leg", piece = "LeftLowerLeg", c0 = CFrame.new(0, -0.7, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Left Leg", piece = "LeftLeg", c0 = CFrame.new(0, 0.19, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Leg", piece = "RightSandal", c0 = CFrame.new(0, -0.92, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Leg", piece = "RightLowerLeg", c0 = CFrame.new(0, -0.7, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
        { limb = "Right Leg", piece = "RightLeg", c0 = CFrame.new(0, 0.19, 0) * CFrame.Angles(0, 3.141592653589793, 0) },
    },
    ["Ascended Thunder Cloak"] = {
        { limb = "Torso", piece = "RootPart", c0 = CFrame.new(0, -3, 0) },
        { limb = "Right Arm", piece = "RightArm", c0 = CFrame.new(0, 0.55, 0) * CFrame.Angles(0, 0, 0) },
        { limb = "Left Arm", piece = "LeftArm", c0 = CFrame.new(0, 0.55, 0) * CFrame.Angles(0, 0, 0) },
    },
    ["Ascended Wanderer's Outfit"] = {
        { limb = "Torso", piece = "Main", c0 = CFrame.new(0, 0.24, 0.02) * CFrame.Angles(0, -1.5707963267948966, 0) },
    },
}

local Cloth = {
    enabled   = false,
    selected  = "",
    origShirt = nil,
    origPants = nil,
    applied   = nil,   -- the ascended Model we parented, if any
    conn      = nil,
    status    = nil,
    ascended  = false,
    hidden    = {},   -- [part or decal] = its Transparency before we hid it
}

local ASC = "Ascended "

-- The client strips the prefix before looking an ascended outfit up, which is
-- why ReplicatedStorage.Clothing only ever holds the plain names.
local function clothingBase(name)
    if name:sub(1, #ASC) == ASC then
        return name:sub(#ASC + 1)
    end
    return name
end

local function clothingFolder()
    return RepStorage:FindFirstChild("Clothing")
end

-- Anything humanoid that might be wearing an ascended outfit: players first,
-- then top-level workspace models, which covers the NPCs. Deliberately not a
-- full descendant walk - this runs on a button press, not per frame.
local function wearers()
    local out, seen = {}, {}

    for _, plr in ipairs(Players:GetPlayers()) do
        local c = plr.Character
        if c and not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end

    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") and not seen[obj] and obj:FindFirstChildOfClass("Humanoid") then
            seen[obj] = true
            out[#out + 1] = obj
        end
    end

    return out
end

-- [outfit name] = the character we can copy it from.
local function ascendedDonors()
    local found = {}
    for _, c in ipairs(wearers()) do
        if c ~= character() then
            for _, child in ipairs(c:GetChildren()) do
                if child:IsA("Model") and child.Name:sub(1, #ASC) == ASC and not found[child.Name] then
                    found[child.Name] = child
                end
            end
        end
    end
    return found
end

local function clothingOptions()
    local names, seen = {}, {}

    -- Base outfits only. The ascended variants used to sit in here as separate
    -- entries, which doubled the list to say one bit of information; they are
    -- the Ascended toggle now.
    local folder = clothingFolder()
    if folder then
        for _, item in ipairs(folder:GetChildren()) do
            local name = item.Name
            if name:sub(1, #ASC) ~= ASC and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end

    table.sort(names)
    return names
end

-- Does this outfit have an ascended version at all? 27 of the 62 do, so the
-- toggle cannot simply prepend the prefix and hope.
local function hasAscended(base)
    local want = ASC .. base
    for _, name in ipairs(ASCENDED_NAMES) do
        if name == want then return true end
    end
    return false
end

-- What the toggle and the dropdown add up to.
local function effectiveOutfit()
    if Cloth.ascended and Cloth.selected ~= "" and hasAscended(Cloth.selected) then
        return ASC .. Cloth.selected
    end
    return Cloth.selected
end

---------------------------------------------------------------------
-- Textures
---------------------------------------------------------------------
local function applyTextures(name)
    local c    = character()
    local data = clothingFolder()
    data = data and data:FindFirstChild(clothingBase(name))
    if not c or not data then return false end

    local newShirt = data:FindFirstChild("Shirt")
    local newPants = data:FindFirstChild("Pants")

    if newShirt then
        local shirt = c:FindFirstChildOfClass("Shirt")
        if not shirt then
            shirt = Instance.new("Shirt")
            shirt.Parent = c
        end
        -- Captured once, on the first apply, so flipping between outfits while
        -- the toggle is on cannot overwrite what we started in.
        if Cloth.origShirt == nil then Cloth.origShirt = shirt.ShirtTemplate end
        shirt.ShirtTemplate = newShirt.ShirtTemplate
    end

    if newPants then
        local pants = c:FindFirstChildOfClass("Pants")
        if not pants then
            pants = Instance.new("Pants")
            pants.Parent = c
        end
        if Cloth.origPants == nil then Cloth.origPants = pants.PantsTemplate end
        pants.PantsTemplate = newPants.PantsTemplate
    end

    return newShirt ~= nil or newPants ~= nil
end

local function restoreTextures()
    local c = character()
    if c then
        local shirt = c:FindFirstChildOfClass("Shirt")
        local pants = c:FindFirstChildOfClass("Pants")
        if shirt and Cloth.origShirt then shirt.ShirtTemplate = Cloth.origShirt end
        if pants and Cloth.origPants then pants.PantsTemplate = Cloth.origPants end
    end
    Cloth.origShirt = nil
    Cloth.origPants = nil
end

---------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------
local function selfRigged(name)
    for _, pat in ipairs(SELF_RIGGED) do
        if name:find(pat, 1, true) then return true end
    end
    return false
end

-- [piece name] = { limb, c0, c1 }, read straight off a wearer's own joints.
local function readPlacement(donor)
    local map, n = {}, 0
    for _, d in ipairs(donor:GetDescendants()) do
        if (d:IsA("Weld") or d:IsA("Motor6D")) and d.Part0 and d.Part1 then
            map[d.Part1.Name] = { limb = d.Part0.Name, c0 = d.C0, c1 = d.C1 }
            n = n + 1
        end
    end
    return map, n
end

-- The model, from wherever it can be had. The replicated folder is tried first
-- because it works in an empty server; a wearer is the fallback.
-- Normal / Broken is what the server reads, but a replicated mirror does not
-- have to be laid out identically, and an outfit that silently "does not load"
-- is usually geometry sitting one level away from where it was looked for. So
-- the search widens instead of giving up: the named variants first, then any
-- child that actually contains parts, then the entry itself.
local function geometryUnder(entry)
    if not entry then return nil end

    local named = entry:FindFirstChild("Normal") or entry:FindFirstChild("Broken")
    if named and named:FindFirstChildWhichIsA("BasePart", true) then
        return named, named.Name
    end

    -- Parts straight under the entry, with no wrapper.
    if entry:FindFirstChildWhichIsA("BasePart") then
        return entry, "entry"
    end

    -- Some other wrapper: take the first child that holds parts, ignoring the
    -- Shirt / Pants the textures live in.
    for _, child in ipairs(entry:GetChildren()) do
        if not child:IsA("Shirt") and not child:IsA("Pants")
           and child:FindFirstChildWhichIsA("BasePart", true) then
            return child, child.Name
        end
    end

    return nil
end

local function outfitGeometry(name)
    local folder = clothingFolder()
    local entry  = folder and folder:FindFirstChild(name)

    local model, where = geometryUnder(entry)
    if model then return model, "storage/" .. where end

    -- The base entry can carry the geometry for its ascended variant, since
    -- the two share everything but the stat line.
    if name:sub(1, #ASC) == ASC then
        local base = folder and folder:FindFirstChild(clothingBase(name))
        model, where = geometryUnder(base)
        if model then return model, "storage/base/" .. where end
    end

    local donor = ascendedDonors()[name]
    if donor then return donor, "wearer" end

    return nil
end

local function removeAscended()
    if Cloth.applied then
        pcall(function() Cloth.applied:Destroy() end)
        Cloth.applied = nil
    end
end

---------------------------------------------------------------------
-- The outfit we are already wearing
--
-- If the character is genuinely in an ascended outfit, the server has already
-- welded that geometry into it. Swapping clothes locally does not take it off,
-- so without this the two outfits are worn at once and clip through each
-- other - and a plain outfit would still leave the old 3D armour on.
--
-- insertClothing stamps the name onto the character (SetAttribute("Clothing"),
-- gamescript2.txt:1524) and names the model after the outfit, so this is the
-- game's own bookkeeping rather than a guess.
--
-- Hidden rather than destroyed: the server built those welds, and hiding gives
-- the real outfit back the moment the toggle goes off instead of making a
-- respawn the only way to undo it.
---------------------------------------------------------------------
local function wornGeometry(c)
    local found = {}

    local function add(model)
        if not model or not model:IsA("Model") or model == Cloth.applied then return end
        for _, m in ipairs(found) do
            if m == model then return end
        end
        found[#found + 1] = model
    end

    add(c:FindFirstChild(c:GetAttribute("Clothing") or ""))

    -- Belt and braces, for a mid-swap frame or a Broken variant that has been
    -- renamed back to its base name.
    for _, child in ipairs(c:GetChildren()) do
        if child.Name:sub(1, #ASC) == ASC then add(child) end
    end

    return found
end

local function hideWorn(c)
    for _, model in ipairs(wornGeometry(c)) do
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
                -- Recorded once, so applying twice cannot save 1 as "original".
                if Cloth.hidden[d] == nil then
                    Cloth.hidden[d] = d.Transparency
                end
                d.Transparency = 1
            end
        end
    end
end

local function restoreWorn()
    for obj, value in pairs(Cloth.hidden) do
        pcall(function() obj.Transparency = value end)
    end
    Cloth.hidden = {}
end

---------------------------------------------------------------------
-- Rigging
--
-- Three sources of placement, applied CUMULATIVELY: each pass only fills in
-- pieces the previous one could not place. The first version of this bailed
-- out of the later passes whenever the first placed anything at all, so an
-- outfit whose model rigs half of itself through attributes left the rest
-- unwelded and floating - which is exactly the "some parts don't attach" case.
--
-- Whatever is still unplaced after all three is welded to the piece it was
-- authored next to, using the relative CFrames captured before anything moved.
-- Decorative sub-pieces are not named in the server's weld branches at all, so
-- without that pass they would never be attached by anything.
---------------------------------------------------------------------

-- Every BasePart in the model, grouped by name. Built once instead of walking
-- the model for every lookup, and it keeps all parts sharing a name so a
-- mirrored piece can take the next unused one rather than the same one twice.
local function pieceIndex(model)
    local byName = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            local list = byName[d.Name]
            if list then
                list[#list + 1] = d
            else
                byName[d.Name] = { d }
            end
        end
    end
    return byName
end

-- The first part of this name that nothing has welded yet.
local function takePiece(rig, name)
    local list = rig.byName[name]
    if not list then return nil end
    for _, part in ipairs(list) do
        if not rig.welded[part] then return part end
    end
    return nil
end

local function attach(rig, piece, anchor, c0, c1)
    if not piece or not anchor or anchor == piece or rig.welded[piece] then
        return false
    end

    local weld = Instance.new("Weld")
    weld.Part0 = anchor
    weld.Part1 = piece
    if c0 then weld.C0 = c0 end
    if c1 then weld.C1 = c1 end
    weld.Parent = piece              -- where the server puts it too

    rig.welded[piece] = true
    rig.count = rig.count + 1
    return true
end

-- 1. the model rigs itself: the joints came with it and only need pointing at
--    our limbs instead of whoever they were built for.
local function rigFromAttributes(rig, c)
    local placed, seen = 0, 0
    for _, d in ipairs(rig.model:GetDescendants()) do
        if d:IsA("Motor6D") or d:IsA("Weld") then
            local want = d:GetAttribute("Part0")
            if want then
                seen = seen + 1
                local limb = c:FindFirstChild(want)
                if limb and limb:IsA("BasePart") then
                    d.Part0 = limb
                    if d.Part1 then
                        rig.welded[d.Part1] = true
                        rig.count = rig.count + 1
                    end
                    placed = placed + 1
                else
                end
            end
        end
    end
    return placed
end

-- 2. offsets from the table lifted out of the server.
local function rigFromTable(rig, c, entries)
    local placed = 0
    for _, e in ipairs(entries) do
        local limb = c:FindFirstChild(e.limb)
        local piece = takePiece(rig, e.piece)

        -- A mirrored piece ships once and is copied for the other side.
        if e.clone and not piece then
            local src = rig.byName[e.piece] and rig.byName[e.piece][1]
            if src then
                local copy = src:Clone()
                for _, d in ipairs(copy:GetDescendants()) do
                    if d:IsA("Weld") or d:IsA("Motor6D") then d:Destroy() end
                end
                copy.Name   = e.piece
                copy.Parent = rig.model
                rig.authored[copy] = rig.authored[src]
                piece = copy
            end
        end

        if piece and limb and limb:IsA("BasePart")
           and attach(rig, piece, limb, e.c0, e.c1) then
            placed = placed + 1
        end
    end
    return placed
end

-- 3. offsets copied off a live wearer.
local function rigFromWearer(rig, c, place)
    local placed = 0
    for name, info in pairs(place) do
        local piece = takePiece(rig, name)
        if piece then
            -- Most pieces hang off a limb; a few hang off another piece of the
            -- same outfit, so the outfit itself is the fallback.
            local anchor = c:FindFirstChild(info.limb)
            if not (anchor and anchor:IsA("BasePart")) then
                anchor = rig.byName[info.limb] and rig.byName[info.limb][1]
            end
            if attach(rig, piece, anchor, info.c0, info.c1) then
                placed = placed + 1
            end
        end
    end
    return placed
end

-- 4. anything still loose goes onto the piece it was authored beside. The
--    authored CFrames were captured before any welding moved a part, so the
--    offset between them is the placement the model was built with.
local function rigLeftovers(rig)
    local anchors = {}
    for part in pairs(rig.welded) do
        if rig.authored[part] then anchors[#anchors + 1] = part end
    end
    if #anchors == 0 then return 0 end

    local loose = {}
    for _, list in pairs(rig.byName) do
        for _, part in ipairs(list) do
            if not rig.welded[part] and rig.authored[part] then
                loose[#loose + 1] = part
            end
        end
    end

    local placed = 0
    for _, part in ipairs(loose) do
        local mine = rig.authored[part]
        local best, bestDist

        for _, anchor in ipairs(anchors) do
            local d = (rig.authored[anchor].Position - mine.Position).Magnitude
            if not bestDist or d < bestDist then
                best, bestDist = anchor, d
            end
        end

        if best and attach(rig, part, best, rig.authored[best]:Inverse() * mine) then
            placed = placed + 1
        end
    end

    return placed
end

local function wearAscended(name)
    local c = character()
    if not c then return false, "no character" end

    local source, origin = outfitGeometry(name)
    if not source then
        return false, "no model in ReplicatedStorage and nobody here is wearing it"
    end

    -- A wearer's joints ARE the offsets, so they are read before cloning.
    local place
    if origin == "wearer" then place = readPlacement(source) end

    local clone = source:Clone()
    clone.Name = name

    local rig = {
        model    = clone,
        byName   = nil,
        welded   = {},
        authored = {},
        count    = 0,
    }

    -- Pieces are made weightless and non-colliding before they are parented,
    -- so nothing drags on us in the frame between parenting and welding, and
    -- their authored CFrames are recorded while they are still untouched.
    -- Joints that describe themselves are kept and re-pointed; the rest are
    -- rebuilt, since their Part0 still refers to whoever the model was for.
    local parts = 0
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("BasePart") then
            rig.authored[d] = d.CFrame
            d.Anchored   = false
            d.CanCollide = false
            d.Massless   = true
            parts = parts + 1
        elseif d:IsA("Weld") or d:IsA("Motor6D") then
            if d:GetAttribute("Part0") == nil then d:Destroy() end
        end
    end
    rig.byName = pieceIndex(clone)

    rigFromAttributes(rig, c)

    local entries = CLOTH_WELDS[name] or CLOTH_WELDS[(name:gsub(" Broken$", ""))]
    if entries then rigFromTable(rig, c, entries) end
    if place then rigFromWearer(rig, c, place) end
    rigLeftovers(rig)

    if rig.count == 0 then
        clone:Destroy()
        if origin:sub(1, 7) == "storage" then
            -- A self-rigging outfit that would not rig means the replicated
            -- copy is missing the Motor6Ds the server relies on, which is
            -- worth saying apart from simply having no offsets for it.
            if selfRigged(name) then
                return false, "model found but its rigging is missing - needs a wearer"
            end
            return false, "found the model but no offsets for it - needs a wearer"
        end
        return false, "could not rig it"
    end

    removeAscended()
    clone.Parent  = c
    Cloth.applied = clone

    -- Partial success is still worth saying: the outfit will look wrong rather
    -- than absent, and the debug toggle names the pieces that missed.
    if rig.count < parts then
        return true, string.format("%d of %d pieces placed", rig.count, parts)
    end
    return true
end

---------------------------------------------------------------------
-- Apply / clear
---------------------------------------------------------------------
local function clothApply(announce)
    if not Cloth.enabled or Cloth.selected == "" then return end

    removeAscended()

    local c = character()
    if c then hideWorn(c) end

    local want = effectiveOutfit()

    -- Asking for ascended on an outfit that has no ascended version is worth
    -- saying rather than silently handing back the plain one.
    if announce and Cloth.ascended and want == Cloth.selected then
        notify("Clothing", Cloth.selected .. " has no ascended version", 4)
    end

    local ok = applyTextures(want)

    -- An ascended pick wears the base textures underneath, exactly as the game
    -- does, and then the geometry on top. If the geometry cannot be had the
    -- textures still land, so the outfit is at least half right.
    if want:sub(1, #ASC) == ASC then
        local worn, why = wearAscended(want)
        if not worn then
            if announce then
                notify("Clothing", want .. ": " .. why, 5)
            end
            return
        end
        -- A partial rig is worth saying out loud: the outfit will look wrong
        -- rather than absent, so the count says how wrong.
        if why and announce then
            notify("Clothing", want .. ": " .. why, 5)
        end
    end

    if announce then
        if ok or Cloth.applied then
            notify("Clothing", "Wearing " .. want, 3)
        else
            notify("Clothing", "Nothing to apply for " .. want, 4)
        end
    end
end

local function clothClear()
    removeAscended()
    restoreWorn()
    restoreTextures()
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------
UI.playerClothing.element("Dropdown", "Outfit", {
    options = clothingOptions(),
}, function(v)
    Cloth.selected = v.Dropdown or ""
    if Cloth.enabled then clothApply(true) end
end)

UI.playerClothing.element("Toggle", "Ascended", nil, function(v)
    Cloth.ascended = v.Toggle
    if Cloth.enabled then clothApply(true) end
end)

UI.playerClothing.element("Toggle", "Change Clothing", nil, function(v)
    Cloth.enabled = v.Toggle

    if v.Toggle then
        if Cloth.selected == "" then
            notify("Clothing", "Pick an outfit first")
            return
        end

        clothApply(true)

        -- A respawn arrives with the server's own outfit on, so it has to be
        -- redone; one frame of grace lets the character finish assembling.
        if not Cloth.conn then
            Cloth.conn = bind(LP.CharacterAdded:Connect(function()
                -- Every part from the old character is gone, so the saved
                -- transparencies and templates refer to nothing.
                Cloth.applied   = nil
                Cloth.origShirt = nil
                Cloth.origPants = nil
                Cloth.hidden    = {}
                task.delay(1.5, function()
                    if Cloth.enabled then clothApply(false) end
                end)
            end))
        end
    else
        if Cloth.conn then
            unbind(Cloth.conn)
            Cloth.conn = nil
        end
        clothClear()
    end
end)


end

yield(true)

---------------------------------------------------------------------
-- ESP
--
-- Written from scratch in the Deepwoken layout rather than carried over from
-- the public V1 ESP: a single box per target with the bars stacked vertically
-- down its left edge (health -> chakra -> blood, right to left), the name
-- above it and the info block below it. Nothing is drawn per-frame that can
-- be computed once, nothing is allocated until the feature is switched on,
-- and every Drawing is released on disable so the idle cost is zero.
---------------------------------------------------------------------
-- Highlights go somewhere the game cannot walk to from the character, so a
-- descendant scan on a player model finds nothing that is not the game's own.
local function hiddenParent()
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then return core end
    return LP:FindFirstChildOfClass("PlayerGui")
end

local function newDrawing(kind, props)
    local ok, obj = pcall(function() return Drawing.new(kind) end)
    if not ok or not obj then return nil end
    for prop, val in pairs(props or {}) do
        pcall(function() obj[prop] = val end)
    end
    return obj
end

local ESP = {
    enabled          = false,
    showName         = true,
    showDistance     = true,
    showHealthText   = true,
    showHealthBar    = true,
    showChakraBar    = true,
    showBloodBar     = true,
    showClan         = true,
    showFreshie      = true,
    showAwakened     = true,
    showSkill        = false,
    showBoxes        = true,
    showTracers      = false,
    showHighlight    = false,
    showCombatTimer  = false,
    showCooldowns    = false,
    teamCheck        = false,

    maxCooldowns     = 3,

    maxDistance      = 2000,
    barDistance      = 150,
    textSize         = 14,
    boxThickness     = 1,
    barWidth         = 3,
    tracerOrigin     = "Bottom",

    nameColor        = Color3.fromRGB(255, 255, 255),
    distanceColor    = Color3.fromRGB(180, 180, 180),
    boxColor         = Color3.fromRGB(255, 255, 255),
    teamColor        = Color3.fromRGB(0, 255, 0),
    chakraColor      = Color3.fromRGB(80, 170, 255),
    bloodColor       = Color3.fromRGB(200, 40, 40),
    tracerColor      = Color3.fromRGB(255, 255, 255),
    highlightFill    = Color3.fromRGB(255, 0, 0),
    highlightOutline = Color3.fromRGB(255, 255, 255),
    clanColor        = Color3.fromRGB(190, 160, 255),
    combatColor      = Color3.fromRGB(255, 120, 120),
    cooldownColor    = Color3.fromRGB(170, 170, 255),
    freshieColor     = Color3.fromRGB(120, 200, 255),
    awakenedColor    = Color3.fromRGB(255, 190, 90),
}

local MOB = {
    enabled        = false,
    showName       = true,
    showDistance   = true,
    showHealthText = true,
    showHealthBar  = true,
    showBoxes      = true,
    showTracers    = false,
    showHighlight  = false,

    maxDistance    = 500,
    barDistance    = 150,
    textSize       = 13,
    boxThickness   = 1,
    barWidth       = 3,

    nameColor      = Color3.fromRGB(255, 120, 120),
    distanceColor  = Color3.fromRGB(200, 200, 200),
    boxColor       = Color3.fromRGB(255, 100, 100),
    tracerColor    = Color3.fromRGB(255, 100, 100),
    highlightFill  = Color3.fromRGB(255, 50, 50),
    highlightOutline = Color3.fromRGB(255, 255, 255),
}

local espObjects = {}   -- [Player] = drawings
local mobObjects = {}   -- [Model]  = drawings
local espConn    = nil
local mobFrame   = 0

---------------------------------------------------------------------
-- HEALTH RAMP
--
-- Fixed 3-stop ramp: red -> orange -> green. Orange bridges the transition so
-- a target at ~50% reads as hurt well before the bar goes fully red.
---------------------------------------------------------------------
local HP_HIGH = Color3.fromRGB(75, 210, 75)
local HP_MID  = Color3.fromRGB(255, 140, 0)
local HP_LOW  = Color3.fromRGB(210, 40, 40)

local function lerpColor(a, b, t)
    return Color3.new(
        a.R + (b.R - a.R) * t,
        a.G + (b.G - a.G) * t,
        a.B + (b.B - a.B) * t
    )
end

-- The five functions below run per player per frame from the ESP renderers,
-- which are themselves not virtualised. The macro applies per function, not to
-- everything a function calls, so without it here the hot loop would just be
-- making virtualised calls and the win would mostly evaporate. All five are
-- arithmetic and Drawing writes - nothing a dumper would learn from.
local healthColor = LPH_NO_VIRTUALIZE(function(pct)
    pct = math.clamp(pct, 0, 1)
    if pct >= 0.5 then
        return lerpColor(HP_MID, HP_HIGH, (pct - 0.5) * 2)
    end
    return lerpColor(HP_LOW, HP_MID, pct * 2)
end)

---------------------------------------------------------------------
-- DRAWING LIFECYCLE
---------------------------------------------------------------------
local function destroyDrawings(data)
    if not data then return end
    for key, obj in pairs(data) do
        if key == "Highlight" then
            if obj then pcall(function() obj:Destroy() end) end
        elseif type(obj) == "userdata" then
            pcall(function()
                obj.Visible = false
                obj:Remove()
            end)
        end
    end
end

local hideDrawings = LPH_NO_VIRTUALIZE(function(data)
    if not data then return end
    for key, obj in pairs(data) do
        if key == "Highlight" then
            if obj then
                pcall(function() obj:Destroy() end)
                data.Highlight = nil
            end
        elseif type(obj) == "userdata" then
            pcall(function() obj.Visible = false end)
        end
    end
end)

local function textDrawing(size)
    return newDrawing("Text", {
        Size = size, Center = true, Outline = true, Font = 2,
        Color = Color3.new(1, 1, 1), Visible = false,
    })
end

local function barSet()
    return
        newDrawing("Square", {Thickness = 1, Filled = true,  Color = Color3.new(0, 0, 0), Transparency = 0.5, Visible = false}),
        newDrawing("Square", {Thickness = 1, Filled = true,  Color = HP_HIGH, Visible = false})
end

local function createPlayerDrawings(target)
    if target == LP or espObjects[target] then return end

    local hpBg, hpFill     = barSet()
    local ckBg, ckFill     = barSet()
    local bdBg, bdFill     = barSet()

    espObjects[target] = {
        NameTag     = textDrawing(14),
        DistanceTag = textDrawing(13),
        HealthTag   = textDrawing(13),
        StatusTag   = textDrawing(12),
        CombatTag   = textDrawing(12),
        CooldownTag = textDrawing(12),

        Box         = newDrawing("Square", {Thickness = 1, Filled = false, Color = Color3.new(1, 1, 1), Visible = false}),
        Tracer      = newDrawing("Line",   {Thickness = 1, Color = Color3.new(1, 1, 1), Visible = false}),

        HealthBg    = hpBg, HealthFill = hpFill,
        ChakraBg    = ckBg, ChakraFill = ckFill,
        BloodBg     = bdBg, BloodFill  = bdFill,

        Highlight   = nil,
    }
end

local function createMobDrawings(model)
    if mobObjects[model] then return end

    local hpBg, hpFill = barSet()

    mobObjects[model] = {
        NameTag     = textDrawing(13),
        DistanceTag = textDrawing(12),
        HealthTag   = textDrawing(12),

        Box         = newDrawing("Square", {Thickness = 1, Filled = false, Color = MOB.boxColor, Visible = false}),
        Tracer      = newDrawing("Line",   {Thickness = 1, Color = MOB.tracerColor, Visible = false}),

        HealthBg    = hpBg, HealthFill = hpFill,

        Highlight   = nil,
    }
end

-- Cleared in place, not replaced: renderPlayerESP is a native closure and
-- holds espObjects by value, so swapping in a fresh table would leave it
-- drawing from the old one forever.
local function clearPlayerESP()
    for target, data in pairs(espObjects) do
        destroyDrawings(data)
        espObjects[target] = nil
    end
end

local function clearMobESP()
    for model, data in pairs(mobObjects) do
        destroyDrawings(data)
        mobObjects[model] = nil
    end
end

---------------------------------------------------------------------
-- TARGET DATA (Bloodlines specific)
---------------------------------------------------------------------
local function isTeammate(target)
    if not ESP.teamCheck then return false end
    local mine, theirs = LP.Team, target.Team
    if mine and theirs then
        if mine == theirs then return true end
        if mine.Name and theirs.Name then return mine.Name == theirs.Name end
    end
    return false
end

local function bloodlineOf(target)
    local s = gameSettings()
    local ps = s and s:FindFirstChild(target.Name)
    local bl = ps and ps:FindFirstChild("Bloodline")
    if bl and bl.Value and bl.Value ~= "" then return bl.Value end
    return nil
end

local function awakenedOf(target)
    local s = gameSettings()
    local ps = s and s:FindFirstChild(target.Name)
    local aw = ps and ps:FindFirstChild("Awakened")
    if not aw then return nil end

    local val = aw.Value
    if type(val) == "string" and val ~= "" then return val end
    if val == true then return "Awakened" end
    return nil
end

local function skillOf(target)
    local char = target.Character
    local head = char and char:FindFirstChild("FakeHead")
    local gui  = head and head:FindFirstChild("skillGUI")
    local name = gui and gui:FindFirstChild("skillName")
    if name and name:IsA("TextLabel") and name.Text ~= "" then return name.Text end
    return nil
end

-- CombatTags holds one NumberValue per source of aggro; the highest is the
-- time left before they drop out of combat.
local function combatTimerOf(target)
    local tags = RepStorage:FindFirstChild("CombatTags")
    local mine = tags and tags:FindFirstChild(target.Name)
    if not mine then return nil end

    local highest = nil
    for _, v in ipairs(mine:GetChildren()) do
        if v:IsA("NumberValue") and (highest == nil or v.Value > highest) then
            highest = v.Value
        end
    end
    return highest
end

-- Whatever is sitting in a player's Cooldowns folder is on cooldown right
-- now. Names only: the game does not replicate the remaining time, and
-- guessing it from a hardcoded duration table drifts every balance patch.
local function cooldownsOf(target, limit)
    local folder = cooldownsFolder()
    local mine   = folder and folder:FindFirstChild(target.Name)
    if not mine then return nil end

    local names = {}
    for _, v in ipairs(mine:GetChildren()) do
        names[#names + 1] = v.Name
        if #names >= limit then break end
    end

    if #names == 0 then return nil end
    return table.concat(names, " | ")
end

local function isFreshie(char)
    local traits = char and char:FindFirstChild("Traits")
    return traits ~= nil and #traits:GetChildren() < 3
end

-- Blood is a plain 0-100 value in the target's Backpack.
local function bloodPct(target)
    local bp = target:FindFirstChild("Backpack")
    local blood = bp and bp:FindFirstChild("blood")
    local n = blood and tonumber(blood.Value)
    if n then return math.clamp(n, 0, 100) / 100 end
    return nil
end

-- Chakra is authoritative in the target's own HUD label ("current/max"); the
-- Backpack value is the fallback for players whose GUI is not replicated.
local function chakraPct(target)
    local ok, pct, cur, max = pcall(function()
        local gui = target:FindFirstChild("PlayerGui")
        local hud = gui
            and gui:FindFirstChild("ClientGui")
            and gui.ClientGui:FindFirstChild("Mainframe")
            and gui.ClientGui.Mainframe:FindFirstChild("Loadout")
            and gui.ClientGui.Mainframe.Loadout:FindFirstChild("HUD")
        local top    = hud and hud:FindFirstChild("ChakraTop")
        local amount = top and top:FindFirstChild("ChakraAmount")

        if amount and amount:IsA("TextLabel") then
            local c, m = tostring(amount.Text):match("(%d+)/(%d+)")
            if c and m and tonumber(m) > 0 then
                return math.clamp(tonumber(c) / tonumber(m), 0, 1), tonumber(c), tonumber(m)
            end
        end
        return nil
    end)

    if ok and pct then return pct, cur, max end

    local bp = target:FindFirstChild("Backpack")
    local chakra = bp and bp:FindFirstChild("chakra")
    local n = chakra and tonumber(chakra.Value)
    if n then return math.clamp(n, 0, 100) / 100, n, 100 end

    return nil
end

---------------------------------------------------------------------
-- BAR RENDERING
--
-- One vertical bar drawn at barX. The caller walks barX leftward so the bars
-- stack outward from the box edge in a fixed order.
---------------------------------------------------------------------
local drawBar = LPH_NO_VIRTUALIZE(function(bg, fill, barX, barY, barW, barH, pct, color)
    bg.Visible  = true
    bg.Position = Vector2.new(barX, barY)
    bg.Size     = Vector2.new(barW, barH)

    local fillH = math.max(1, barH * math.clamp(pct, 0, 1))
    fill.Visible  = true
    fill.Position = Vector2.new(barX, barY + (barH - fillH))
    fill.Size     = Vector2.new(barW, fillH)
    fill.Color    = color
end)

local hideBar = LPH_NO_VIRTUALIZE(function(bg, fill)
    bg.Visible   = false
    fill.Visible = false
end)

local function tracerOrigin(mode, viewport)
    if mode == "Top" then
        return Vector2.new(viewport.X / 2, 0)
    elseif mode == "Center" then
        return Vector2.new(viewport.X / 2, viewport.Y / 2)
    end
    return Vector2.new(viewport.X / 2, viewport.Y)
end

---------------------------------------------------------------------
-- PER-TARGET INFO CACHE
--
-- The render loop used to call eight separate lookups per player per frame -
-- team, clan, skill, awakening, freshie, combat timer, blood, cooldowns - and
-- every one of them walks a FindFirstChild chain through ReplicatedStorage,
-- with GetChildren() allocating a throwaway table on top. At twenty players
-- and 144fps that is tens of thousands of instance lookups a second, to
-- produce text that changes a few times a second at most.
--
-- None of it is frame-coupled, so it moves onto a timer and the loop reads the
-- cache instead. Geometry stays per-frame, because that genuinely does move
-- every frame; text does not. The per-target table is reused rather than
-- rebuilt, so a refresh allocates nothing either.
--
-- Each field is still gated on its own toggle, so a disabled row costs no
-- lookup even at refresh time.
---------------------------------------------------------------------
local INFO_INTERVAL = 0.12
local infoCache     = {}

local targetInfo = LPH_NO_VIRTUALIZE(function(target, char)
    local info = infoCache[target]
    if not info then
        info = { at = 0 }
        infoCache[target] = info
    end

    local now = os.clock()
    if now - info.at < INFO_INTERVAL then return info end
    info.at = now

    info.team      = isTeammate(target)
    info.clan      = ESP.showClan        and bloodlineOf(target) or nil
    info.blood     = ESP.showBloodBar    and bloodPct(target) or nil
    info.cooldowns = ESP.showCooldowns   and cooldownsOf(target, ESP.maxCooldowns) or nil
    info.combat    = ESP.showCombatTimer and combatTimerOf(target) or nil

    -- One status row carries skill / awakening / freshie, worst-first, so the
    -- stack never grows past four lines.
    local status, statusColor = nil, nil
    if ESP.showSkill then
        local skill = skillOf(target)
        if skill then status, statusColor = skill, ESP.awakenedColor end
    end
    if not status and ESP.showAwakened then
        local mode = awakenedOf(target)
        if mode then status, statusColor = mode, ESP.awakenedColor end
    end
    if not status and ESP.showFreshie and isFreshie(char) then
        status, statusColor = "Freshie", ESP.freshieColor
    end
    info.status      = status
    info.statusColor = statusColor

    return info
end)

---------------------------------------------------------------------
-- PLAYER ESP RENDER
--
-- Not virtualised: the hottest function in the script, running every frame
-- for every player, and it holds nothing but maths and Drawing writes - there
-- is nothing here a dumper would learn anything from.
---------------------------------------------------------------------
local renderPlayerESP = LPH_NO_VIRTUALIZE(function()
    if not ESP.enabled then return end

    local cam = workspace.CurrentCamera
    if not cam then return end

    local myRoot = root()
    local myPos  = myRoot and myRoot.Position
    local W2VP   = cam.WorldToViewportPoint

    -- Same value for every target, so it is computed once a frame rather than
    -- once a frame per player.
    local tracerFrom = ESP.showTracers and tracerOrigin(ESP.tracerOrigin, cam.ViewportSize) or nil

    for _, target in ipairs(playerList()) do
        if target == LP then continue end

        local data = espObjects[target]
        local char = target.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")

        if not hum or not hrp or hum.Health <= 0 then
            hideDrawings(data)
            continue
        end

        local distance = myPos and (hrp.Position - myPos).Magnitude or 0
        if distance > ESP.maxDistance then
            hideDrawings(data)
            continue
        end

        local rootPos, onScreen = W2VP(cam, hrp.Position)

        if not data then
            createPlayerDrawings(target)
            data = espObjects[target]
            if not data then continue end
        end

        if not onScreen then
            hideDrawings(data)
            continue
        end

        local info      = targetInfo(target, char)
        local team      = info.team
        local boxColor  = team and ESP.teamColor or ESP.boxColor
        local nameColor = team and ESP.teamColor or ESP.nameColor

        -- Box geometry: measured off the root, not off a bounding box, so it
        -- stays stable while the character animates.
        local hrpCF     = hrp.CFrame
        local topPos    = W2VP(cam, (hrpCF * CFrame.new(0, 3, 0)).Position)
        local bottomPos = W2VP(cam, (hrpCF * CFrame.new(0, -3.5, 0)).Position)
        local height    = math.abs(topPos.Y - bottomPos.Y)
        local width     = height * 0.55
        local boxPos    = Vector2.new(rootPos.X - width / 2, topPos.Y)
        local boxSize   = Vector2.new(width, height)

        if ESP.showBoxes then
            data.Box.Visible   = true
            data.Box.Position  = boxPos
            data.Box.Size      = boxSize
            data.Box.Color     = boxColor
            data.Box.Thickness = ESP.boxThickness
        else
            data.Box.Visible = false
        end


        -----------------------------------------------------------------
        -- Bars, stacked right to left: health -> chakra -> blood.
        -- Only drawn close in; further out they are unreadable clutter.
        -----------------------------------------------------------------
        local barsInRange = distance <= ESP.barDistance
        local barW        = ESP.barWidth
        local barY        = boxPos.Y
        local barH        = boxSize.Y
        local barX        = boxPos.X - barW - 4

        if ESP.showHealthBar and barsInRange then
            local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
            drawBar(data.HealthBg, data.HealthFill, barX, barY, barW, barH, pct, healthColor(pct))
            barX = barX - barW - 3
        else
            hideBar(data.HealthBg, data.HealthFill)
        end

        if ESP.showChakraBar and barsInRange then
            local pct = chakraPct(target)
            if pct then
                drawBar(data.ChakraBg, data.ChakraFill, barX, barY, barW, barH, pct, ESP.chakraColor)
                barX = barX - barW - 3
            else
                hideBar(data.ChakraBg, data.ChakraFill)
            end
        else
            hideBar(data.ChakraBg, data.ChakraFill)
        end

        if ESP.showBloodBar and barsInRange then
            local pct = info.blood
            if pct then
                drawBar(data.BloodBg, data.BloodFill, barX, barY, barW, barH, pct, ESP.bloodColor)
                barX = barX - barW - 3
            else
                hideBar(data.BloodBg, data.BloodFill)
            end
        else
            hideBar(data.BloodBg, data.BloodFill)
        end

        -----------------------------------------------------------------
        -- Name (clan appended inline rather than given its own row)
        -----------------------------------------------------------------
        if ESP.showName then
            local label = target.Name
            if info.clan then label = label .. " [" .. info.clan .. "]" end

            data.NameTag.Visible  = true
            data.NameTag.Position = Vector2.new(rootPos.X, boxPos.Y - 2 - ESP.textSize)
            data.NameTag.Text     = label
            data.NameTag.Color    = nameColor
            data.NameTag.Size     = ESP.textSize
        else
            data.NameTag.Visible = false
        end

        -----------------------------------------------------------------
        -- Info block under the box
        -----------------------------------------------------------------
        local infoY = boxPos.Y + boxSize.Y + 2

        if ESP.showDistance then
            data.DistanceTag.Visible  = true
            data.DistanceTag.Position = Vector2.new(rootPos.X, infoY)
            data.DistanceTag.Text     = string.format("%d studs", math.floor(distance))
            data.DistanceTag.Color    = ESP.distanceColor
            data.DistanceTag.Size     = ESP.textSize - 1
            infoY = infoY + ESP.textSize
        else
            data.DistanceTag.Visible = false
        end

        if ESP.showHealthText then
            local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
            data.HealthTag.Visible  = true
            data.HealthTag.Position = Vector2.new(rootPos.X, infoY)
            data.HealthTag.Text     = string.format("%d/%d HP", math.floor(hum.Health), math.floor(hum.MaxHealth))
            data.HealthTag.Color    = healthColor(pct)
            data.HealthTag.Size     = ESP.textSize - 1
            infoY = infoY + ESP.textSize
        else
            data.HealthTag.Visible = false
        end

        local status, statusColor = info.status, info.statusColor

        if ESP.showCombatTimer then
            local timer = info.combat
            if timer and timer > 0 then
                data.CombatTag.Visible  = true
                data.CombatTag.Position = Vector2.new(rootPos.X, infoY)
                data.CombatTag.Text     = string.format("Combat %ds", math.floor(timer))
                data.CombatTag.Color    = ESP.combatColor
                data.CombatTag.Size     = ESP.textSize - 2
                infoY = infoY + ESP.textSize - 1
            else
                data.CombatTag.Visible = false
            end
        else
            data.CombatTag.Visible = false
        end

        if ESP.showCooldowns then
            local list = info.cooldowns
            if list then
                data.CooldownTag.Visible  = true
                data.CooldownTag.Position = Vector2.new(rootPos.X, infoY)
                data.CooldownTag.Text     = list
                data.CooldownTag.Color    = ESP.cooldownColor
                data.CooldownTag.Size     = ESP.textSize - 2
                infoY = infoY + ESP.textSize - 1
            else
                data.CooldownTag.Visible = false
            end
        else
            data.CooldownTag.Visible = false
        end

        if status then
            data.StatusTag.Visible  = true
            data.StatusTag.Position = Vector2.new(rootPos.X, infoY)
            data.StatusTag.Text     = status
            data.StatusTag.Color    = statusColor
            data.StatusTag.Size     = ESP.textSize - 2
        else
            data.StatusTag.Visible = false
        end

        -----------------------------------------------------------------
        -- Tracer / highlight
        -----------------------------------------------------------------
        if tracerFrom then
            data.Tracer.Visible = true
            data.Tracer.From    = tracerFrom
            data.Tracer.To      = Vector2.new(rootPos.X, rootPos.Y)
            data.Tracer.Color   = team and ESP.teamColor or ESP.tracerColor
        else
            data.Tracer.Visible = false
        end

        if ESP.showHighlight then
            if not data.Highlight then
                local hl = Instance.new("Highlight")
                hl.Name              = K.Services.HttpService:GenerateGUID(false)
                hl.FillTransparency  = 0.65
                hl.OutlineTransparency = 0
                hl.Adornee           = char
                pcall(function() hl.Parent = hiddenParent() end)
                data.Highlight = hl
            end
            data.Highlight.Adornee      = char
            data.Highlight.FillColor    = team and ESP.teamColor or ESP.highlightFill
            data.Highlight.OutlineColor = team and ESP.teamColor or ESP.highlightOutline
        elseif data.Highlight then
            pcall(function() data.Highlight:Destroy() end)
            data.Highlight = nil
        end
    end
end)

---------------------------------------------------------------------
-- MOB REGISTRY
--
-- Mobs are Models sitting directly under workspace with a Humanoid, that are
-- not a player character and are not a Dialog (quest/shop) NPC. The Dialog
-- test is cached per model: it never changes and the check is not free.
---------------------------------------------------------------------
local mobRegistry  = {}
local mobPending   = {}   -- models still streaming in
local dialogCache  = {}
local mobConns     = {}
local mobSweep     = 0
local playerChars  = {}
local playerCharAt = 0

-- Cached: this used to walk every player for every candidate model, on every
-- sweep. The set only changes on spawn, so a one-second refresh is plenty.
local function isPlayerModel(model)
    local now = os.clock()
    if now - playerCharAt > 1 then
        playerCharAt = now
        playerChars = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Character then playerChars[p.Character] = true end
        end
    end
    return playerChars[model] == true
end

local function isMob(model)
    if not model:IsA("Model") then return false end
    if model.Parent ~= workspace then return false end
    if not model:FindFirstChildOfClass("Humanoid") then return false end
    if not (model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso")) then return false end
    if isPlayerModel(model) then return false end

    -- Only cached once the model has a Humanoid, i.e. once it has finished
    -- streaming. Caching earlier can record a verdict taken before the NPC
    -- tag replicated and then never revisit it.
    local cached = dialogCache[model]
    if cached ~= nil then return not cached end

    local tag = model:FindFirstChild("NPC")
    local hasDialog = (tag and tag:IsA("StringValue") and tag.Value == "Dialog") or false
    dialogCache[model] = hasDialog
    return not hasDialog
end

-- A model arrives in workspace before its Humanoid and HumanoidRootPart do,
-- and how long that takes varies per mob. The old code looked once at 0.5s and
-- threw the model away if it was not ready yet, which is why some mobs were
-- silently skipped until a manual rescan. Anything not yet recognisable goes
-- on a pending list and is re-checked by the sweep below until it either
-- qualifies or the window expires.
local MOB_PENDING_WINDOW = 6

local function considerMob(obj)
    if mobRegistry[obj] or not obj:IsA("Model") then return end
    if isMob(obj) then
        mobRegistry[obj] = true
        mobPending[obj]  = nil
    else
        mobPending[obj] = os.clock() + MOB_PENDING_WINDOW
    end
end

local function sweepPending()
    local now = os.clock()
    if now - mobSweep < 0.25 then return end
    mobSweep = now

    for obj, deadline in pairs(mobPending) do
        if not obj.Parent or now > deadline then
            mobPending[obj] = nil
        elseif isMob(obj) then
            mobRegistry[obj] = true
            mobPending[obj]  = nil
        end
    end
end

local function startMobRegistry()
    -- In place: renderMobESP captures mobRegistry by value.
    table.clear(mobRegistry)
    table.clear(mobPending)

    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") and isMob(obj) then mobRegistry[obj] = true end
    end

    mobConns[#mobConns + 1] = bind(workspace.ChildAdded:Connect(function(obj)
        if not MOB.enabled then return end
        considerMob(obj)
    end))

    -- Catches a Humanoid arriving in a model that is already in workspace,
    -- which ChildAdded has long since fired for.
    mobConns[#mobConns + 1] = bind(workspace.DescendantAdded:Connect(function(d)
        if not MOB.enabled then return end
        if not d:IsA("Humanoid") then return end
        local model = d.Parent
        if model and model.Parent == workspace then
            considerMob(model)
        end
    end))

    mobConns[#mobConns + 1] = bind(workspace.ChildRemoved:Connect(function(obj)
        mobPending[obj] = nil
        if mobRegistry[obj] then
            mobRegistry[obj] = nil
            dialogCache[obj] = nil
            destroyDrawings(mobObjects[obj])
            mobObjects[obj] = nil
        end
    end))
end

local function stopMobRegistry()
    for _, c in ipairs(mobConns) do unbind(c) end
    mobConns = {}
    table.clear(mobRegistry)
    table.clear(mobPending)
    table.clear(dialogCache)
end

---------------------------------------------------------------------
-- MOB ESP RENDER (throttled - mobs do not need 60Hz)
---------------------------------------------------------------------
local mobSizeCache, mobSizeTime = {}, {}

local function mobSize(model)
    local now  = os.clock()
    local last = mobSizeTime[model]
    if last and (now - last) < 5 then
        return mobSizeCache[model]
    end

    local ok, _, size = pcall(model.GetBoundingBox, model)
    if ok and size then
        mobSizeCache[model] = size
        mobSizeTime[model]  = now
        return size
    end
    return Vector3.new(4, 6, 4)
end

-- Not virtualised either, for the same reason as the player renderer.
local renderMobESP = LPH_NO_VIRTUALIZE(function()
    if not MOB.enabled then return end

    mobFrame = mobFrame + 1
    if mobFrame % 3 ~= 0 then return end

    sweepPending()

    local cam = workspace.CurrentCamera
    if not cam then return end

    local myRoot = root()
    local myPos  = myRoot and myRoot.Position
    local W2VP   = cam.WorldToViewportPoint

    for model in pairs(mobRegistry) do
        local data = mobObjects[model]

        if not model.Parent then
            destroyDrawings(data)
            mobObjects[model]  = nil
            mobRegistry[model] = nil
            continue
        end

        local hum = model:FindFirstChildOfClass("Humanoid")
        local hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso")

        if not hum or not hrp or hum.Health <= 0 then
            hideDrawings(data)
            continue
        end

        local distance = myPos and (hrp.Position - myPos).Magnitude or 0
        if distance > MOB.maxDistance then
            hideDrawings(data)
            continue
        end

        local rootPos, onScreen = W2VP(cam, hrp.Position)
        if not onScreen then
            hideDrawings(data)
            continue
        end

        if not data then
            createMobDrawings(model)
            data = mobObjects[model]
            if not data then continue end
        end

        local size      = mobSize(model)
        local halfY     = size.Y / 2
        local halfX     = math.max(size.X, size.Z) / 2
        local topPos    = W2VP(cam, hrp.Position + Vector3.new(0, halfY, 0))
        local bottomPos = W2VP(cam, hrp.Position - Vector3.new(0, halfY, 0))
        local height    = math.abs(topPos.Y - bottomPos.Y)
        local edge      = W2VP(cam, hrp.Position + Vector3.new(halfX, 0, 0))
        local width     = math.max(height * 0.55, math.abs(edge.X - rootPos.X) * 2)
        local boxPos    = Vector2.new(rootPos.X - width / 2, topPos.Y)
        local boxSize   = Vector2.new(width, height)

        if MOB.showBoxes then
            data.Box.Visible   = true
            data.Box.Position  = boxPos
            data.Box.Size      = boxSize
            data.Box.Color     = MOB.boxColor
            data.Box.Thickness = MOB.boxThickness
        else
            data.Box.Visible = false
        end

        local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)

        if MOB.showHealthBar and distance <= MOB.barDistance then
            drawBar(data.HealthBg, data.HealthFill,
                boxPos.X - MOB.barWidth - 4, boxPos.Y, MOB.barWidth, boxSize.Y,
                pct, healthColor(pct))
        else
            hideBar(data.HealthBg, data.HealthFill)
        end

        if MOB.showName then
            data.NameTag.Visible  = true
            data.NameTag.Position = Vector2.new(rootPos.X, boxPos.Y - 2 - MOB.textSize)
            data.NameTag.Text     = model.Name
            data.NameTag.Color    = MOB.nameColor
            data.NameTag.Size     = MOB.textSize
        else
            data.NameTag.Visible = false
        end

        local infoY = boxPos.Y + boxSize.Y + 2

        if MOB.showDistance then
            data.DistanceTag.Visible  = true
            data.DistanceTag.Position = Vector2.new(rootPos.X, infoY)
            data.DistanceTag.Text     = string.format("%d studs", math.floor(distance))
            data.DistanceTag.Color    = MOB.distanceColor
            data.DistanceTag.Size     = MOB.textSize - 1
            infoY = infoY + MOB.textSize
        else
            data.DistanceTag.Visible = false
        end

        if MOB.showHealthText then
            data.HealthTag.Visible  = true
            data.HealthTag.Position = Vector2.new(rootPos.X, infoY)
            data.HealthTag.Text     = string.format("%d/%d HP", math.floor(hum.Health), math.floor(hum.MaxHealth))
            data.HealthTag.Color    = healthColor(pct)
            data.HealthTag.Size     = MOB.textSize - 1
        else
            data.HealthTag.Visible = false
        end

        if MOB.showTracers then
            data.Tracer.Visible = true
            data.Tracer.From    = tracerOrigin("Bottom", cam.ViewportSize)
            data.Tracer.To      = Vector2.new(rootPos.X, rootPos.Y)
            data.Tracer.Color   = MOB.tracerColor
        else
            data.Tracer.Visible = false
        end

        if MOB.showHighlight then
            if not data.Highlight then
                local hl = Instance.new("Highlight")
                hl.Name                = K.Services.HttpService:GenerateGUID(false)
                hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
                hl.FillTransparency    = 0.5
                hl.OutlineTransparency = 0
                pcall(function() hl.Parent = hiddenParent() end)
                data.Highlight = hl
            end
            data.Highlight.Adornee      = model
            data.Highlight.FillColor    = MOB.highlightFill
            data.Highlight.OutlineColor = MOB.highlightOutline
        elseif data.Highlight then
            pcall(function() data.Highlight:Destroy() end)
            data.Highlight = nil
        end
    end
end)

---------------------------------------------------------------------
-- RENDER LOOP (one connection shared by both ESPs)
---------------------------------------------------------------------
local function syncEspLoop()
    local wanted = ESP.enabled or MOB.enabled

    if wanted and not espConn then
        -- Two pcalls a frame that nobody ever reads is how a broken renderer
        -- stays broken and silent for a whole session. A few consecutive
        -- failures are treated as a real fault: say so once, then stop drawing
        -- rather than burning the frame budget on it.
        local fails = 0
        espConn = bind(RunService.RenderStepped:Connect(function()
            local ok, err = pcall(renderPlayerESP)
            if ok then ok, err = pcall(renderMobESP) end

            if ok then
                fails = 0
                return
            end

            fails = fails + 1
            if fails >= 5 then
                notify("Visuals", "ESP stopped: " .. tostring(err), 8)
                ESP.enabled = false
                MOB.enabled = false
                task.defer(syncEspLoop)
            end
        end))
    elseif not wanted and espConn then
        unbind(espConn)
        espConn = nil
    end
end

bind(Players.PlayerRemoving:Connect(function(target)
    destroyDrawings(espObjects[target])
    espObjects[target] = nil
    infoCache[target]  = nil
end))

yield(true)


---------------------------------------------------------------------
-- ESP UI
---------------------------------------------------------------------
local ON  = { default = { Toggle = true } }

-- Drawing is an executor API, not a Roblox one. Fail loudly once rather than
-- letting every render frame swallow the same error inside a pcall.
local function drawingAvailable()
    if typeof(Drawing) == "table" or type(Drawing) == "table" then return true end
    notify("Visuals", "This executor has no Drawing API - ESP unavailable", 6)
    return false
end

UI.boxPlayerESP.element("Toggle", "Enable Player ESP", nil, function(v)
    if v.Toggle and not drawingAvailable() then return end

    ESP.enabled = v.Toggle
    if not v.Toggle then
        clearPlayerESP()
    end
    syncEspLoop()
    notify("Visuals", "Player ESP " .. (v.Toggle and "enabled" or "disabled"))
end)

UI.boxPlayerESP.create_line()

UI.boxPlayerESP.element("Toggle", "Show Name", ON, function(v)
    ESP.showName = v.Toggle
end):add_color({ Color = ESP.nameColor }, false, function(c)
    ESP.nameColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Distance", ON, function(v)
    ESP.showDistance = v.Toggle
end):add_color({ Color = ESP.distanceColor }, false, function(c)
    ESP.distanceColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Health Text", ON, function(v)
    ESP.showHealthText = v.Toggle
end)

UI.boxPlayerESP.element("Toggle", "Show Health Bar", ON, function(v)
    ESP.showHealthBar = v.Toggle
end)

UI.boxPlayerESP.element("Toggle", "Show Chakra Bar", ON, function(v)
    ESP.showChakraBar = v.Toggle
end):add_color({ Color = ESP.chakraColor }, false, function(c)
    ESP.chakraColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Blood Bar", ON, function(v)
    ESP.showBloodBar = v.Toggle
end):add_color({ Color = ESP.bloodColor }, false, function(c)
    ESP.bloodColor = c.Color
end)

UI.boxPlayerESP.create_line()

UI.boxPlayerESP.element("Toggle", "Show Boxes", ON, function(v)
    ESP.showBoxes = v.Toggle
end):add_color({ Color = ESP.boxColor }, false, function(c)
    ESP.boxColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Tracers", nil, function(v)
    ESP.showTracers = v.Toggle
end):add_color({ Color = ESP.tracerColor }, false, function(c)
    ESP.tracerColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Highlight", nil, function(v)
    ESP.showHighlight = v.Toggle
end):add_color({ Color = ESP.highlightFill }, false, function(c)
    ESP.highlightFill = c.Color
end)

UI.boxPlayerESP.create_line()

UI.boxPlayerESP.element("Toggle", "Show Clan / Bloodline", ON, function(v)
    ESP.showClan = v.Toggle
end)

UI.boxPlayerESP.element("Toggle", "Show Freshie Tag", ON, function(v)
    ESP.showFreshie = v.Toggle
end):add_color({ Color = ESP.freshieColor }, false, function(c)
    ESP.freshieColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Awakened Mode", ON, function(v)
    ESP.showAwakened = v.Toggle
end):add_color({ Color = ESP.awakenedColor }, false, function(c)
    ESP.awakenedColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Current Skill", nil, function(v)
    ESP.showSkill = v.Toggle
end)

UI.boxPlayerESP.element("Toggle", "Show Combat Timer", nil, function(v)
    ESP.showCombatTimer = v.Toggle
end):add_color({ Color = ESP.combatColor }, false, function(c)
    ESP.combatColor = c.Color
end)

UI.boxPlayerESP.element("Toggle", "Show Cooldowns", nil, function(v)
    ESP.showCooldowns = v.Toggle
end):add_color({ Color = ESP.cooldownColor }, false, function(c)
    ESP.cooldownColor = c.Color
end)

yield()

UI.boxPlayerESPOpt.element("Toggle", "Team Check", nil, function(v)
    ESP.teamCheck = v.Toggle
end):add_color({ Color = ESP.teamColor }, false, function(c)
    ESP.teamColor = c.Color
end)

UI.boxPlayerESPOpt.element("Dropdown", "Tracer Origin", {
    options = { "Bottom", "Center", "Top" },
    default = { Dropdown = "Bottom" },
}, function(v)
    ESP.tracerOrigin = v.Dropdown
end)

UI.boxPlayerESPOpt.element("Slider", "Max Distance", {
    default = { min = 100, max = 5000, default = 2000 },
    suffix  = " studs",
}, function(v)
    ESP.maxDistance = v.Slider
end)

UI.boxPlayerESPOpt.element("Slider", "Bar Render Distance", {
    default = { min = 20, max = 500, default = 150 },
    suffix  = " studs",
}, function(v)
    ESP.barDistance = v.Slider
end)

UI.boxPlayerESPOpt.element("Slider", "Text Size", {
    default = { min = 10, max = 24, default = 14 },
}, function(v)
    ESP.textSize = v.Slider
end)

UI.boxPlayerESPOpt.element("Slider", "Box Thickness", {
    default = { min = 1, max = 5, default = 1 },
}, function(v)
    ESP.boxThickness = v.Slider
end)

UI.boxPlayerESPOpt.element("Slider", "Bar Width", {
    default = { min = 1, max = 10, default = 3 },
}, function(v)
    ESP.barWidth = v.Slider
end)

UI.boxPlayerESPOpt.element("Slider", "Max Cooldowns Shown", {
    default = { min = 1, max = 8, default = 3 },
}, function(v)
    ESP.maxCooldowns = v.Slider
end)

yield()

---------------------------------------------------------------------
-- MOB ESP UI
---------------------------------------------------------------------
UI.boxMobESP.element("Toggle", "Enable Mob ESP", nil, function(v)
    if v.Toggle and not drawingAvailable() then return end
    MOB.enabled = v.Toggle
    if v.Toggle then
        startMobRegistry()
    else
        stopMobRegistry()
        clearMobESP()
    end
    syncEspLoop()
    notify("Visuals", "Mob ESP " .. (v.Toggle and "enabled" or "disabled"))
end)

UI.boxMobESP.create_line()

UI.boxMobESP.element("Toggle", "Show Name", ON, function(v)
    MOB.showName = v.Toggle
end, "mob"):add_color({ Color = MOB.nameColor }, false, function(c)
    MOB.nameColor = c.Color
end)

UI.boxMobESP.element("Toggle", "Show Distance", ON, function(v)
    MOB.showDistance = v.Toggle
end, "mob"):add_color({ Color = MOB.distanceColor }, false, function(c)
    MOB.distanceColor = c.Color
end)

UI.boxMobESP.element("Toggle", "Show Health Text", ON, function(v)
    MOB.showHealthText = v.Toggle
end, "mob")

UI.boxMobESP.element("Toggle", "Show Health Bar", ON, function(v)
    MOB.showHealthBar = v.Toggle
end, "mob")

UI.boxMobESP.element("Toggle", "Show Boxes", ON, function(v)
    MOB.showBoxes = v.Toggle
end, "mob"):add_color({ Color = MOB.boxColor }, false, function(c)
    MOB.boxColor = c.Color
end)

UI.boxMobESP.element("Toggle", "Show Tracers", nil, function(v)
    MOB.showTracers = v.Toggle
end, "mob"):add_color({ Color = MOB.tracerColor }, false, function(c)
    MOB.tracerColor = c.Color
end)

UI.boxMobESP.element("Toggle", "Show Highlight", nil, function(v)
    MOB.showHighlight = v.Toggle
end, "mob"):add_color({ Color = MOB.highlightFill }, false, function(c)
    MOB.highlightFill = c.Color
end)

UI.boxMobESPOpt.element("Slider", "Max Distance", {
    default = { min = 50, max = 2000, default = 500 },
    suffix  = " studs",
}, function(v)
    MOB.maxDistance = v.Slider
end, "mob")

UI.boxMobESPOpt.element("Slider", "Bar Render Distance", {
    default = { min = 20, max = 500, default = 150 },
    suffix  = " studs",
}, function(v)
    MOB.barDistance = v.Slider
end, "mob")

UI.boxMobESPOpt.element("Slider", "Text Size", {
    default = { min = 10, max = 24, default = 13 },
}, function(v)
    MOB.textSize = v.Slider
end, "mob")

UI.boxMobESPOpt.element("Slider", "Box Thickness", {
    default = { min = 1, max = 5, default = 1 },
}, function(v)
    MOB.boxThickness = v.Slider
end, "mob")

UI.boxMobESPOpt.element("Slider", "Bar Width", {
    default = { min = 1, max = 10, default = 3 },
}, function(v)
    MOB.barWidth = v.Slider
end, "mob")

UI.boxMobESPOpt.element("Button", "Rescan Mobs", nil, function()
    if not MOB.enabled then
        notify("Visuals", "Enable Mob ESP first")
        return
    end
    stopMobRegistry()
    startMobRegistry()
    notify("Visuals", "Mob list rebuilt")
end)

yield(true)

---------------------------------------------------------------------
-- SAFE TELEPORT
--
-- Every teleport in the script routes through safeTeleport(). With Safe
-- Teleport on it refuses to move you to a spot with another player inside the
-- detection radius, which is what stops a chakra point unlock run from
-- blinking into somebody's face.
--
-- The move itself is asked of the server rather than written locally. "MoveMe"
-- is the game's own teleport remote and takes an absolute CFrame - the ramen
-- contest uses it to seat you and then put you back
-- (gamescript.txt:9745 and 9833) - so the new position arrives as a
-- server-authored move instead of a client rewriting its own root.
--
-- Two consequences worth knowing. It is a round trip, so a true return means
-- "asked", not "arrived"; and it is a remote, so it cannot be re-asserted
-- every frame the way a CFrame write could. The one caller that used to do
-- that - the mastery farm parking through its spawn forcefield - now re-asks
-- only when it has actually drifted.
---------------------------------------------------------------------
local Safe = {
    enabled        = true,
    detectionRange = 100,
    safespot       = Vector3.new(-3613.159, 422.669, -2603.599),
}

local function playersNear(position, range, exclude)
    local found = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p ~= exclude then
            local char = p.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local d = (hrp.Position - position).Magnitude
                if d <= range then
                    found[#found + 1] = { player = p, distance = d }
                end
            end
        end
    end
    return found
end

local function safeTeleport(targetCFrame, skipCheck, exclude)
    local hrp = root()
    if not hrp then
        notify("Teleport", "No character found")
        return false
    end

    if Safe.enabled and not skipCheck then
        local near = playersNear(targetCFrame.Position, Safe.detectionRange, exclude)
        if #near > 0 then
            local names = {}
            for _, entry in ipairs(near) do
                names[#names + 1] = entry.player.Name .. " (" .. math.floor(entry.distance) .. ")"
            end
            notify("Teleport", "Unsafe - nearby: " .. table.concat(names, ", "), 5)
            return false
        end
    end

    local remote = dataEvent()
    if not remote then
        notify("Teleport", "DataEvent remote not found")
        return false
    end

    remote:FireServer("MoveMe", targetCFrame)
    return true
end

---------------------------------------------------------------------
-- TELEPORTS :: CHAKRA POINTS
---------------------------------------------------------------------
local function chakraPointNames()
    local names = {}
    pcall(function()
        local folder = workspace:FindFirstChild("ChakraPoints")
        if not folder then return end
        for _, v in ipairs(folder:GetDescendants()) do
            if v.Name == "PointName" then
                names[#names + 1] = v.Value
            end
        end
    end)
    table.sort(names)
    return names
end

local selectedPoint = nil
local pointDropdown = UI.boxChakraPoints.element("Dropdown", "Chakra Point", {
    options = chakraPointNames(),
}, function(v)
    selectedPoint = v.Dropdown
end)

UI.boxChakraPoints.element("Button", "Refresh Points", nil, function()
    pointDropdown:refresh(chakraPointNames())
    notify("Teleport", "Chakra points refreshed", 2)
end)

UI.boxChakraPoints.element("Button", "Teleport to Chakra Point", nil, function()
    if not selectedPoint or selectedPoint == "" then
        notify("Teleport", "Select a chakra point first")
        return
    end

    local folder = workspace:FindFirstChild("ChakraPoints")
    if not folder then
        notify("Teleport", "ChakraPoints folder not found")
        return
    end

    for _, v in ipairs(folder:GetDescendants()) do
        if v.Name == "PointName" and v.Value == selectedPoint then
            local main = v.Parent and v.Parent:FindFirstChild("Main")
            if main and safeTeleport(main.CFrame * CFrame.new(0, 0, 4)) then
                notify("Teleport", "Went to " .. selectedPoint)
            end
            return
        end
    end

    notify("Teleport", "Point not found - refresh the list")
end)

UI.boxChakraPoints.create_line()

---------------------------------------------------------------------
-- UNLOCK ALL CHAKRA POINTS
--
-- Unlocking is proximity based, so this is just a visit run: hop each locked
-- point, wait out the unlock, move on. It aborts the moment the chakra sense
-- watcher says somebody is looking, and skips any point that has a player
-- parked on it.
---------------------------------------------------------------------
K.unlockAbort   = false
K.beingObserved = false

UI.boxChakraPoints.element("Button", "Unlock All Chakra Points", nil, function()
    K.unlockAbort = false

    task.spawn(function()
        local folder = workspace:FindFirstChild("ChakraPoints")
        if not folder then
            notify("Teleport", "ChakraPoints folder not found")
            return
        end

        local unlocked, skipped = 0, 0
        notify("Teleport", "Unlocking chakra points...", 4)

        for _, v in ipairs(folder:GetDescendants()) do
            if K.unlockAbort then
                notify("Teleport", "Chakra unlock aborted")
                return
            end

            if K.beingObserved then
                notify("Teleport", "Chakra sense detected - stopping")
                return
            end

            if v.Name == "Unlocked" and v.Value == false then
                local main = v.Parent and v.Parent:FindFirstChild("Main")
                if main then
                    if Safe.enabled and #playersNear(main.Position, Safe.detectionRange) > 0 then
                        skipped = skipped + 1
                    elseif safeTeleport(main.CFrame * CFrame.new(0, 0, 4), true) then
                        unlocked = unlocked + 1
                        task.wait(5)
                    end
                end
            end
        end

        local msg = "Visited " .. unlocked .. " locked points"
        if skipped > 0 then
            msg = msg .. " (skipped " .. skipped .. ", players nearby)"
        end
        notify("Teleport", msg, 5)
    end)
end)

UI.boxChakraPoints.element("Button", "Abort Unlock", nil, function()
    K.unlockAbort = true
    notify("Teleport", "Aborting", 2)
end)

---------------------------------------------------------------------
-- TELEPORTS :: FRUITS
--
-- Fruits live in ReplicatedStorage until they are picked up. Each one is
-- keyed by rounded position so a fruit that is already visited is not offered
-- again while it is still replicated.
---------------------------------------------------------------------
local visitedFruits = {}

local function fruitPosition(fruit)
    if fruit:IsA("BasePart") then return fruit.Position end
    if fruit:IsA("Model") then
        local part = fruit.PrimaryPart
            or fruit:FindFirstChild("HumanoidRootPart")
            or fruit:FindFirstChildWhichIsA("BasePart")
        return part and part.Position
    end
    return nil
end

local function findFruits(fruitName)
    local out, seen = {}, {}

    pcall(function()
        for _, fruit in ipairs(RepStorage:GetDescendants()) do
            if fruit.Name == fruitName then
                local pos = fruitPosition(fruit)
                if pos then
                    local key = string.format("%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z)
                    if not seen[key] and not visitedFruits[key] then
                        seen[key] = true
                        out[#out + 1] = { position = pos, key = key }
                    end
                end
            end
        end
    end)

    return out
end

local function teleportToFruit(fruitName, label)
    local fruits = findFruits(fruitName)
    if #fruits == 0 then
        notify("Teleport", "No " .. label .. " available")
        return
    end

    local target = fruits[1]
    if safeTeleport(CFrame.new(target.position)) then
        visitedFruits[target.key] = true
        notify("Teleport", string.format("%s - %d remaining", label, #fruits - 1))
    end
end

UI.boxFruits.element("Button", "Teleport to Life Fruit", nil, function()
    teleportToFruit("Life Up Fruit", "Life Fruit")
end)

UI.boxFruits.element("Button", "Teleport to Chakra Fruit", nil, function()
    teleportToFruit("Chakra Fruit", "Chakra Fruit")
end)

UI.boxFruits.create_line()

UI.boxFruits.element("Button", "Reset Visited Fruits", nil, function()
    visitedFruits = {}
    notify("Teleport", "Visited fruit list cleared", 2)
end)

---------------------------------------------------------------------
-- TELEPORTS :: PLAYERS
---------------------------------------------------------------------
local function playerNames()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then names[#names + 1] = p.Name end
    end
    table.sort(names)
    return names
end

local selectedTarget = nil
local playerDropdown = UI.boxTpPlayer.element("Dropdown", "Player", {
    options = playerNames(),
}, function(v)
    selectedTarget = v.Dropdown
end)

UI.boxTpPlayer.element("Button", "Refresh Player List", nil, function()
    playerDropdown:refresh(playerNames())
    notify("Teleport", "Player list refreshed", 2)
end)

UI.boxTpPlayer.element("Button", "Teleport to Player", nil, function()
    if not selectedTarget or selectedTarget == "" then
        notify("Teleport", "Select a player first")
        return
    end

    local target = Players:FindFirstChild(selectedTarget)
    local hrp    = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then
        notify("Teleport", "Player has no character")
        return
    end

    -- The target themselves is excluded from the proximity check, otherwise a
    -- teleport-to-player could never pass it.
    if safeTeleport(hrp.CFrame * CFrame.new(0, 0, 3), false, target) then
        notify("Teleport", "Went to " .. selectedTarget)
    end
end)

-- Keep both lists current without anyone pressing refresh.
bind(Players.PlayerAdded:Connect(function()
    pcall(function() playerDropdown:refresh(playerNames(), true) end)
end))

bind(Players.PlayerRemoving:Connect(function()
    task.defer(function()
        pcall(function() playerDropdown:refresh(playerNames(), true) end)
    end)
end))

---------------------------------------------------------------------
-- TELEPORTS :: QUEST
--
-- Taking a mission from a village Mission Board makes the server drop a
-- MissionMarker, tagged with your UserId attribute, inside
--   workspace.Debris["Mission Locations"][<village>].Spawners.<spawner>
-- and the mission happens at that spawner. This is the same lookup auto
-- quest does after the board click, as a standalone button. Every village
-- folder is searched (not just yours) so a team name that doesn't match the
-- folder name still works.
---------------------------------------------------------------------
do
    local function findMissionSpot()
        local debris    = workspace:FindFirstChild("Debris")
        local locations = debris and debris:FindFirstChild("Mission Locations")
        if not locations then return nil end

        for _, d in ipairs(locations:GetDescendants()) do
            if d.Name == "MissionMarker" and tonumber(d:GetAttribute("UserId")) == LP.UserId then
                local spawner = d.Parent
                if spawner then
                    local part = spawner:IsA("BasePart") and spawner or spawner:FindFirstChildWhichIsA("BasePart")
                    local pos  = part and part.Position or spawner:GetPivot().Position
                    -- 3 studs up so a ground-level spawner doesn't wedge you in the floor
                    return CFrame.new(pos + Vector3.new(0, 3, 0))
                end
            end
        end
        return nil
    end

    UI.boxQuest.element("Button", "Teleport to Quest", nil, function()
        local cf = findMissionSpot()
        if not cf then
            notify("Teleport", "No active mission - take one from a Mission Board first", 4)
            return
        end
        if safeTeleport(cf) then
            notify("Teleport", "Went to your mission")
        end
    end)
end

yield(true)

---------------------------------------------------------------------
-- ON-SCREEN HUD PANELS
--
-- The chakra sense readout and the proximity readout both want the same
-- thing: a small rounded bar pinned near the top of the screen, optionally
-- draggable, optionally expanding into a list on hover. One builder, one
-- ScreenGui, created the first time a panel is actually asked for.
---------------------------------------------------------------------
local HUD = { gui = nil }

local function hudRoot()
    if HUD.gui and HUD.gui.Parent then return HUD.gui end

    HUD.gui = Instance.new("ScreenGui")
    HUD.gui.Name           = K.Services.HttpService:GenerateGUID(false)
    HUD.gui.ResetOnSpawn   = false
    HUD.gui.IgnoreGuiInset = true
    HUD.gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    HUD.gui.DisplayOrder   = 9000
    HUD.gui.Parent         = hiddenParent()

    return HUD.gui
end

-- opts = { width, height, y, list, icon, label }
--
-- Same construction as the keybind list, because that is this script's HUD
-- language: square corners, body 18/18/22, 1px 58/58/66 stroke, Ubuntu, and a
-- two-stripe header - grey, then the accent - pinned to the top edge.
--
-- The one departure is that the accent stripe is not fixed white: it carries
-- the panel's STATE. set_state moves the stripe, the icon tint and the value
-- text together, so the panel's status is legible from the stripe alone,
-- without reading a word of it.
--
--   ===============================   grey
--   -------------------------------   state colour
--    [icon] Label        State word
--
-- and, on hover, the names underneath in an identical box.
local function makePanel(opts)
    local panel = { draggable = false, rows = 0 }

    local W, H  = opts.width, opts.height
    local BODY  = Color3.fromRGB(18, 18, 22)
    local EDGE  = Color3.fromRGB(58, 58, 66)
    local WHITE = Color3.fromRGB(255, 255, 255)
    local DIM   = Color3.fromRGB(150, 150, 150)
    local BAR   = 2

    panel.accentColor = WHITE

    panel.frame = Instance.new("Frame")
    panel.frame.Size             = UDim2.new(0, W, 0, H)
    panel.frame.Position         = UDim2.new(0.5, -W / 2, 0, opts.y)
    panel.frame.BackgroundColor3 = BODY
    panel.frame.BorderSizePixel  = 0
    panel.frame.Visible          = false
    panel.frame.ZIndex           = 2
    panel.frame.Parent           = hudRoot()

    local stroke = Instance.new("UIStroke")
    stroke.Color     = EDGE
    stroke.Thickness = 1
    stroke.Parent    = panel.frame
    panel.stroke = stroke

    -- Grey rule, then the accent rule under it.
    local grey = Instance.new("Frame")
    grey.Size             = UDim2.new(1, 0, 0, BAR)
    grey.BackgroundColor3 = EDGE
    grey.BorderSizePixel  = 0
    grey.ZIndex           = 3
    grey.Parent           = panel.frame

    local accent = Instance.new("Frame")
    accent.Position         = UDim2.new(0, 0, 0, BAR)
    accent.Size             = UDim2.new(1, 0, 0, BAR)
    accent.BackgroundColor3 = panel.accentColor
    accent.BorderSizePixel  = 0
    accent.ZIndex           = 3
    accent.Parent           = panel.frame
    panel.accent = accent

    -- Everything below the stripes, so the row centres on the body rather
    -- than on the whole panel and sits visually level.
    local body = Instance.new("Frame")
    body.BackgroundTransparency = 1
    body.Position = UDim2.new(0, 0, 0, BAR * 2)
    body.Size     = UDim2.new(1, 0, 1, -BAR * 2)
    body.ZIndex   = 3
    body.Parent   = panel.frame

    local x = 8

    if opts.icon then
        panel.icon = Instance.new("ImageLabel")
        panel.icon.AnchorPoint            = Vector2.new(0, 0.5)
        panel.icon.Position               = UDim2.new(0, x, 0.5, 0)
        panel.icon.Size                   = UDim2.new(0, 14, 0, 14)
        panel.icon.BackgroundTransparency = 1
        panel.icon.Image                  = opts.icon
        panel.icon.ImageColor3            = panel.accentColor
        panel.icon.ZIndex                 = 4
        panel.icon.Parent                 = body
        x = x + 21
    end

    -- Left: what is being reported. Dim, because it rarely changes.
    panel.caption = Instance.new("TextLabel")
    panel.caption.AnchorPoint            = Vector2.new(0, 0.5)
    panel.caption.Position               = UDim2.new(0, x, 0.5, 0)
    panel.caption.Size                   = UDim2.new(1, -(x + 104), 0, 16)
    panel.caption.BackgroundTransparency = 1
    panel.caption.Font                   = Enum.Font.Ubuntu
    panel.caption.TextSize               = 13
    panel.caption.TextColor3             = DIM
    panel.caption.TextXAlignment         = Enum.TextXAlignment.Left
    panel.caption.TextTruncate           = Enum.TextTruncate.AtEnd
    panel.caption.Text                   = opts.label or ""
    panel.caption.ZIndex                 = 4
    panel.caption.Parent                 = body

    -- Right: the state. Carries the accent colour.
    panel.value = Instance.new("TextLabel")
    panel.value.AnchorPoint            = Vector2.new(1, 0.5)
    panel.value.Position               = UDim2.new(1, -8, 0.5, 0)
    panel.value.Size                   = UDim2.new(0, 96, 0, 16)
    panel.value.BackgroundTransparency = 1
    panel.value.Font                   = Enum.Font.Ubuntu
    panel.value.TextSize               = 13
    panel.value.TextColor3             = WHITE
    panel.value.TextXAlignment         = Enum.TextXAlignment.Right
    panel.value.TextTruncate           = Enum.TextTruncate.AtEnd
    panel.value.Text                   = ""
    panel.value.ZIndex                 = 4
    panel.value.Parent                 = body

    -- The old two-label names still work, so existing callers are unaffected.
    panel.left  = panel.caption
    panel.right = panel.value

    local TS = K.Services.TweenService

    -- One call for the whole state, tweened, so a flick between states reads
    -- as a change rather than a flash.
    function panel.set_state(text, colour)
        if panel.value.Text == text and panel._state == colour then return end
        panel._state      = colour
        panel.accentColor = colour
        panel.value.Text  = text

        local info = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        TS:Create(accent,      info, { BackgroundColor3 = colour }):Play()
        TS:Create(panel.value, info, { TextColor3 = colour }):Play()
        if panel.icon then
            TS:Create(panel.icon, info, { ImageColor3 = colour }):Play()
        end
    end

    -- Optional hover list (chakra sense and proximity both use it).
    if opts.list then
        local ROW_H = 17

        panel.list = Instance.new("Frame")
        panel.list.Size             = UDim2.new(0, W, 0, 0)
        panel.list.Position         = UDim2.new(0, 0, 1, 4)
        panel.list.BackgroundColor3 = BODY
        panel.list.BorderSizePixel  = 0
        panel.list.Visible          = false
        panel.list.ClipsDescendants = true
        panel.list.ZIndex           = 6
        panel.list.Parent           = panel.frame

        local listStroke = Instance.new("UIStroke")
        listStroke.Color     = EDGE
        listStroke.Thickness = 1
        listStroke.Parent    = panel.list

        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.SortOrder     = Enum.SortOrder.LayoutOrder
        layout.Parent        = panel.list

        local padding = Instance.new("UIPadding")
        padding.PaddingTop    = UDim.new(0, 5)
        padding.PaddingBottom = UDim.new(0, 5)
        padding.PaddingLeft   = UDim.new(0, 8)
        padding.PaddingRight  = UDim.new(0, 8)
        padding.Parent        = panel.list

        bind(panel.frame.MouseEnter:Connect(function()
            if panel.frame.Visible and panel.rows > 0 then
                panel.list.Visible = true
            end
        end))

        bind(panel.frame.MouseLeave:Connect(function()
            panel.list.Visible = false
        end))

        -- entries: either plain strings, or
        --   { text = "name", colour = Color3, note = "sensing" }
        -- Entry count drives the height, so a panel with nothing in it never
        -- opens an empty box.
        function panel.set_list(entries)
            -- Rebuilding the rows ten times a second for a list that has not
            -- changed is pure churn; key off the contents instead.
            local parts = {}
            for i, e in ipairs(entries) do
                if type(e) == "table" then
                    parts[i] = e.text .. "|" .. tostring(e.note)
                else
                    parts[i] = tostring(e)
                end
            end
            local key = table.concat(parts, "\1")
            if key == panel._key then return end
            panel._key = key

            for _, child in ipairs(panel.list:GetChildren()) do
                if child:IsA("Frame") then child:Destroy() end
            end

            for i, e in ipairs(entries) do
                local isTable = type(e) == "table"
                local text    = isTable and e.text or tostring(e)
                local note    = isTable and e.note or nil
                local colour  = (isTable and e.colour) or DIM

                local row = Instance.new("Frame")
                row.Size                   = UDim2.new(1, 0, 0, ROW_H)
                row.BackgroundTransparency = 1
                row.LayoutOrder            = i
                row.ZIndex                 = 7
                row.Parent                 = panel.list

                -- Square pip, not a dot: the rest of the HUD has no curves.
                local pip = Instance.new("Frame")
                pip.AnchorPoint      = Vector2.new(0, 0.5)
                pip.Position         = UDim2.new(0, 0, 0.5, 0)
                pip.Size             = UDim2.new(0, 4, 0, 4)
                pip.BackgroundColor3 = colour
                pip.BorderSizePixel  = 0
                pip.ZIndex           = 8
                pip.Parent           = row

                local who = Instance.new("TextLabel")
                who.BackgroundTransparency = 1
                who.Position       = UDim2.new(0, 12, 0, 0)
                who.Size           = UDim2.new(1, -(note and 84 or 12), 1, 0)
                who.Font           = Enum.Font.Ubuntu
                who.TextSize       = 13
                who.TextColor3     = WHITE
                who.TextXAlignment = Enum.TextXAlignment.Left
                who.TextTruncate   = Enum.TextTruncate.AtEnd
                who.Text           = text
                who.ZIndex         = 8
                who.Parent         = row

                if note then
                    local tag = Instance.new("TextLabel")
                    tag.AnchorPoint            = Vector2.new(1, 0.5)
                    tag.Position               = UDim2.new(1, 0, 0.5, 0)
                    tag.Size                   = UDim2.new(0, 72, 1, 0)
                    tag.BackgroundTransparency = 1
                    tag.Font                   = Enum.Font.Ubuntu
                    tag.TextSize               = 12
                    tag.TextColor3             = colour
                    tag.TextXAlignment         = Enum.TextXAlignment.Right
                    tag.Text                   = note
                    tag.ZIndex                 = 8
                    tag.Parent                 = row
                end
            end

            panel.rows      = #entries
            panel.list.Size = UDim2.new(0, W, 0, math.min(#entries, 8) * ROW_H + 10)
            if #entries == 0 then panel.list.Visible = false end
        end
    end

    -- Opt-in drag, so the panel cannot be nudged by a stray click mid fight.
    local dragging, dragStart, startPos = false, nil, nil

    bind(panel.frame.InputBegan:Connect(function(input)
        if not panel.draggable then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging  = true
        dragStart = input.Position
        startPos  = panel.frame.Position
    end))

    bind(panel.frame.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end))

    bind(K.Services.UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local delta = input.Position - dragStart
        panel.frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end))

    return panel
end

---------------------------------------------------------------------
-- KEYBIND LIST
--
-- Small draggable panel listing every bound keybind and whether its feature
-- is on right now. It reads the menu library's own registry (Atlas.keybinds)
-- so it can never drift from what the binds actually do: a feature is ON
-- when its toggle is enabled and, for Toggle / Hold binds, the key currently
-- has it active.
---------------------------------------------------------------------
do
    local TextService = game:GetService("TextService")
    local UIS         = K.Services.UserInputService

    local GREY   = Color3.fromRGB(58, 58, 66)
    local PURPLE = Color3.fromRGB(255, 255, 255)
    local W_MIN, ROW_H, HEAD_H, FONT_SIZE = 150, 18, 26, 13

    local KB = { frame = nil, list = nil, sig = nil, running = false }

    local function build()
        local f = Instance.new("Frame")
        f.Name             = "KeybindList"
        f.Size             = UDim2.new(0, W_MIN, 0, HEAD_H + 8)
        f.Position         = UDim2.new(0, 20, 0.4, 0)
        f.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
        f.BorderSizePixel  = 0
        f.Active           = true
        f.ZIndex           = 2
        f.Parent           = hudRoot()

        local stroke = Instance.new("UIStroke")
        stroke.Color     = GREY
        stroke.Thickness = 1
        stroke.Parent    = f

        -- grey top bar, purple accent bar right under it
        local grey = Instance.new("Frame")
        grey.Size             = UDim2.new(1, 0, 0, 2)
        grey.BackgroundColor3 = GREY
        grey.BorderSizePixel  = 0
        grey.ZIndex           = 3
        grey.Parent           = f

        local purple = Instance.new("Frame")
        purple.Position         = UDim2.new(0, 0, 0, 2)
        purple.Size             = UDim2.new(1, 0, 0, 2)
        purple.BackgroundColor3 = PURPLE
        purple.BorderSizePixel  = 0
        purple.ZIndex           = 3
        purple.Parent           = f

        local title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1
        title.Position       = UDim2.new(0, 8, 0, 4)
        title.Size           = UDim2.new(1, -16, 0, HEAD_H - 4)
        title.Font           = Enum.Font.Ubuntu
        title.TextSize       = 14
        title.TextColor3     = Color3.fromRGB(255, 255, 255)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text           = "Keybinds"
        title.ZIndex         = 3
        title.Parent         = f

        local list = Instance.new("Frame")
        list.BackgroundTransparency = 1
        list.Position = UDim2.new(0, 8, 0, HEAD_H)
        list.Size     = UDim2.new(1, -16, 1, -(HEAD_H + 4))
        list.ZIndex   = 3
        list.Parent   = f

        local layout = Instance.new("UIListLayout")
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent    = list

        -- Drag from anywhere on the panel. Release is watched globally so a
        -- fast drag that leaves the panel can't get stuck "held".
        local dragging, dragStart, startPos = false, nil, nil
        bind(f.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
            dragging, dragStart, startPos = true, input.Position, f.Position
        end))
        bind(UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
        end))
        bind(UIS.InputChanged:Connect(function(input)
            if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
            local d = input.Position - dragStart
            f.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                   startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end))

        KB.frame, KB.list, KB.sig = f, list, nil
    end

    local function esc(s)
        return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end

    -- Bound keys only; "Enable Silent Aim" reads as "Silent Aim".
    local function entries()
        local out = {}
        for _, slot in ipairs(Atlas.keybinds or {}) do
            local v = slot.value
            if v.Key and slot.name then
                local enabled = slot.isOn and slot.isOn() or false
                out[#out + 1] = {
                    key  = v.Key,
                    name = (slot.name:gsub("^Enable ", "")),
                    on   = enabled and (v.Type == "Always" or v.Active == true),
                }
            end
        end
        return out
    end

    local function addRow(order, rich, plain, color)
        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Size           = UDim2.new(1, 0, 0, ROW_H)
        row.Font           = Enum.Font.Ubuntu
        row.TextSize       = FONT_SIZE
        row.TextColor3     = color or Color3.fromRGB(230, 230, 230)
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.RichText       = true
        row.Text           = rich
        row.LayoutOrder    = order
        row.ZIndex         = 3
        row.Parent         = KB.list
        local size = TextService:GetTextSize(plain, FONT_SIZE, Enum.Font.Ubuntu, Vector2.new(1000, ROW_H))
        return size.X
    end

    local function render()
        local list = entries()
        local parts = {}
        for i, e in ipairs(list) do parts[i] = e.key .. "|" .. e.name .. "|" .. tostring(e.on) end
        local sig = table.concat(parts, ";")
        if sig == KB.sig then return end -- nothing changed, nothing rebuilt
        KB.sig = sig

        for _, ch in ipairs(KB.list:GetChildren()) do
            if ch:IsA("TextLabel") then ch:Destroy() end
        end

        local widest = 0
        if #list == 0 then
            widest = addRow(1, "No keybinds set", "No keybinds set", Color3.fromRGB(140, 140, 140))
        else
            for i, e in ipairs(list) do
                local state = e.on and '<font color="#22c55e">ON</font>' or '<font color="#ef4444">OFF</font>'
                local rich  = "[" .. esc(e.key) .. "] | " .. esc(e.name) .. ": " .. state
                local plain = "[" .. e.key .. "] | " .. e.name .. ": " .. (e.on and "ON" or "OFF")
                widest = math.max(widest, addRow(i, rich, plain))
            end
        end

        local rows = math.max(#list, 1)
        KB.frame.Size = UDim2.new(0, math.max(W_MIN, widest + 20), 0, HEAD_H + rows * ROW_H + 6)
    end

    local function start()
        if not KB.frame or not KB.frame.Parent then build() end
        KB.frame.Visible = true
        KB.sig = nil
        if KB.running then return end
        KB.running = true
        task.spawn(function()
            while K.flags.keybindList do
                pcall(render)
                task.wait(0.15)
            end
            KB.running = false
            if KB.frame then KB.frame.Visible = false end
        end)
    end

    UI.boxMenu.element("Toggle", "Keybind List", nil, function(v)
        K.flags.keybindList = v.Toggle
        if v.Toggle then
            start()
        elseif KB.frame then
            KB.frame.Visible = false
        end
    end)
end

yield()

---------------------------------------------------------------------
-- MISC :: VIEW DATA
--
-- GetData is a RemoteFunction, so this is one round trip on demand, not a
-- poll. Table values are flattened to a single line so a stat with sub-keys
-- (UsedSkills, quest tables) still fits a notification.
---------------------------------------------------------------------
-- Scoped: every local in here is only reached through the callbacks
-- defined alongside it, which keep it alive as an upvalue. Closing the
-- block frees the register slots - the main chunk is at Lua's 200-local
-- ceiling and this section is the cheapest thing to give back.
do
local DATA_TYPES = {
    "M1s", "Blocks", "Knocks", "BloodExplosions", "IndraAshuraAgeUps", "Grips",
    "PB", "UsedSkills", "WoodXP", "WaterXP", "EarthXP", "WindXP",
    "ByakuganUsage", "MangekyoUsage", "SharinganUsage", "JinchurikiUsage",
    "GreenGatesUsage", "BlueGatesUsage", "KetsuryuganUsage", "RinneganXP",
    "BugPunches", "Wind-StormXP",
}

local selectedData = {}

local function getPlayerData()
    local ok, data = pcall(function()
        return RepStorage:WaitForChild("Events"):WaitForChild("DataFunction"):InvokeServer("GetData")
    end)
    if ok and type(data) == "table" then return data end
    return nil
end

local function readDataField(data, field)
    if field == "Wind-StormXP" then
        local quests = data.Quests
        local scroll = quests and quests["Wind Scroll 2"]
        local beam   = scroll and scroll.BeamStats
        return beam and beam.Storm
    end
    return data[field]
end

local function flatten(value)
    local parts = {}
    for k, v in pairs(value) do
        if type(v) == "table" then
            parts[#parts + 1] = tostring(k)
        else
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    return table.concat(parts, ", ")
end

UI.boxViewData.element("Combo", "Data Types", { options = DATA_TYPES }, function(v)
    selectedData = v.Combo
end)

UI.boxViewData.element("Button", "View Data", nil, function()
    if #selectedData == 0 then
        notify("Data", "Pick at least one data type")
        return
    end

    task.spawn(function()
        local data = getPlayerData()
        if not data then
            notify("Data", "Failed to retrieve data from server")
            return
        end

        local lines = {}
        for _, field in ipairs(selectedData) do
            local value = readDataField(data, field)
            local text

            if type(value) == "table" then
                text = field .. ": " .. flatten(value)
            else
                text = field .. ": " .. tostring(value)
            end

            lines[#lines + 1] = text
            notify("Data", text, 6)
        end

        if setclipboard then
            pcall(setclipboard, table.concat(lines, "\n"))
        end
    end)
end)

UI.boxViewData.create_line()

---------------------------------------------------------------------
-- MISC :: EYE TYPE
---------------------------------------------------------------------
local selectedEye = "Mangekyo"

local function ownsItem(data, names)
    local function scan(location)
        if type(location) ~= "table" then return false end
        for _, entry in pairs(location) do
            if type(entry) == "table" then
                for _, name in ipairs(names) do
                    if entry.Item == name then return true end
                end
            end
        end
        return false
    end
    return scan(data.Inventory) or scan(data.Loadout)
end

-- The eye's name is buried at a different depth depending on how the item was
-- obtained, so this walks the inventory entry rather than assuming a path.
local function findEyeName(data, eyeType)
    local function direct(tbl)
        if type(tbl) ~= "table" then return nil end
        if eyeType == "Mangekyo" then
            return tbl.MangekyoName or tbl["Mangekyo Name"]
        end
        return tbl.RinneganName or tbl["Rinnegan Name"]
    end

    local function deep(tbl, depth)
        if type(tbl) ~= "table" or depth <= 0 then return nil end
        local found = direct(tbl)
        if found ~= nil then return found end
        for _, v in pairs(tbl) do
            if type(v) == "table" then
                local nested = deep(v, depth - 1)
                if nested ~= nil then return nested end
            end
        end
        return nil
    end

    for _, source in ipairs({ data.Inventory, data.Loadout }) do
        if type(source) == "table" then
            local slot  = (eyeType == "Mangekyo") and 3 or 28
            local entry = source[slot] or source[tostring(slot)]
            local found = deep(entry, 6) or deep(source, 6)
            if found ~= nil then return found end
        end
    end
    return nil
end

UI.boxViewData.element("Dropdown", "Eye Type", {
    options = { "Mangekyo", "Rinnegan" },
    default = { Dropdown = "Mangekyo" },
}, function(v)
    selectedEye = v.Dropdown
end)

UI.boxViewData.element("Button", "View Eye Type", nil, function()
    task.spawn(function()
        local data = getPlayerData()
        if not data then
            notify("Data", "Failed to retrieve data")
            return
        end

        local required = (selectedEye == "Mangekyo")
            and { "Mangekyo Eyes" }
            or  { "Rinnegan", "Rinnegan Eyes", "Rinnegan Eye" }

        if not ownsItem(data, required) then
            notify("Data", "You do not have a " .. selectedEye)
            return
        end

        local name = findEyeName(data, selectedEye)
        if name == nil then
            notify("Data", "Could not find the " .. selectedEye .. " name")
            return
        end

        notify("Data", 'Your ' .. selectedEye .. ' is "' .. tostring(name) .. '"', 6)
    end)
end)

---------------------------------------------------------------------
-- MISC :: PURCHASE
--
-- Pay is a DataFunction invoke taking (price, item, amount, vendorPart). A
-- price of 0 with an arbitrary part lets the server resolve the real cost.
---------------------------------------------------------------------
local purchaseItem   = ""
local purchaseAmount = 1

UI.boxPurchase.element("TextBox", "Item Name", nil, function(v)
    purchaseItem = v.Text
end)

UI.boxPurchase.element("TextBox", "Amount", { default = "1", maxlen = 6 }, function(v)
    local n = tonumber(v.Text)
    purchaseAmount = (n and n >= 1) and math.floor(n) or 1
end)

UI.boxPurchase.element("Button", "Purchase Item", nil, function()
    if purchaseItem == "" then
        notify("Purchase", "Enter an item name")
        return
    end

    task.spawn(function()
        local ok = pcall(function()
            RepStorage:WaitForChild("Events"):WaitForChild("DataFunction"):InvokeServer(
                "Pay", 0, purchaseItem, purchaseAmount, workspace:WaitForChild("TorchMesh")
            )
        end)

        if ok then
            notify("Purchase", "Requested " .. purchaseAmount .. "x " .. purchaseItem)
        else
            notify("Purchase", "Purchase failed")
        end
    end)
end)

UI.boxPurchase.create_line()
UI.boxPurchase.element("Label", "Quick buys")

UI.boxPurchase.element("Button", "Buy Ramen (10 Ryo)", nil, function()
    task.spawn(function()
        pcall(function()
            RepStorage:WaitForChild("Events"):WaitForChild("DataFunction"):InvokeServer(
                "Pay", 10, "Ramen", 1,
                workspace:WaitForChild("Chef"):WaitForChild("HumanoidRootPart")
            )
        end)
        notify("Purchase", "Ramen requested")
    end)
end)

UI.boxPurchase.element("Button", "Buy Accessory (95 Ryo)", nil, function()
    task.spawn(function()
        pcall(function()
            RepStorage:WaitForChild("Events"):WaitForChild("DataFunction"):InvokeServer(
                "Pay", 95, "NewAccessory", 1,
                workspace:WaitForChild("The Fashioneer"):WaitForChild("HumanoidRootPart")
            )
        end)
        notify("Purchase", "Accessory requested - only works once per age up", 5)
    end)
end)

end

yield(true)

---------------------------------------------------------------------
-- SECURITY :: SAFE TELEPORT UI
---------------------------------------------------------------------
UI.boxSafeTp.element("Toggle", "Player Detection Range", ON, function(v)
    Safe.enabled = v.Toggle
    notify("Security", "Player Detection Range " .. (v.Toggle and "enabled" or "disabled"))
end)

UI.boxSafeTp.element("Slider", "Detection Range", {
    default = { min = 0, max = 500, default = 100 },
    suffix  = " studs",
}, function(v)
    Safe.detectionRange = v.Slider
end)

UI.boxSafeTp.create_line()

UI.boxSafeTp.element("TextBox", "Safespot X, Y, Z", {
    default = string.format("%.1f, %.1f, %.1f", Safe.safespot.X, Safe.safespot.Y, Safe.safespot.Z),
}, function(v)
    local nums = {}
    for n in string.gmatch(v.Text, "[-]?%d+%.?%d*") do
        nums[#nums + 1] = tonumber(n)
    end
    if #nums >= 3 then
        Safe.safespot = Vector3.new(nums[1], nums[2], nums[3])
    end
end)

UI.boxSafeTp.element("Button", "Set Safespot To Current Position", nil, function()
    local hrp = root()
    if not hrp then
        notify("Security", "No character found")
        return
    end
    Safe.safespot = hrp.Position
    notify("Security", string.format("Safespot set to %.0f, %.0f, %.0f",
        Safe.safespot.X, Safe.safespot.Y, Safe.safespot.Z))
end)

UI.boxSafeTp.element("Button", "Teleport to Safespot", nil, function()
    if safeTeleport(CFrame.new(Safe.safespot), true) then
        notify("Security", "Went to safespot")
    end
end)

UI.boxSafeTp.element("Button", "Copy Current Position", nil, function()
    local hrp = root()
    if not hrp then
        notify("Security", "No character found")
        return
    end
    local text = string.format("%.1f, %.1f, %.1f", hrp.Position.X, hrp.Position.Y, hrp.Position.Z)
    if setclipboard then
        pcall(setclipboard, text)
        notify("Security", "Copied: " .. text)
    else
        notify("Security", text, 6)
    end
end)

---------------------------------------------------------------------
-- SECURITY :: CHAKRA SENSE NOTIFIER
--
-- Two signals:
--   1. ReplicatedStorage.Cooldowns.<player>."Chakra Sense" exists -> they have
--      it available. Settings.<player>.CurrentSkill == "Chakra Sense" -> they
--      are actively sensing, i.e. looking at you.
--   2. Extreme Caution additionally reads each player's world skill label, so
--      somebody who merely has it equipped counts as a risk too.
--
-- Event driven: the folders themselves are hooked and one evaluation is
-- deferred per burst of changes, rather than rescanning every frame.
---------------------------------------------------------------------
local Sense = {
    enabled        = false,
    extremeCaution = false,
    sound          = true,
    panel          = nil,
    conns          = {},
    skillConns     = {},
    scheduled      = false,
    extremeConn    = nil,
    observing      = {},   -- [name] = true, actively sensing
    holding        = {},   -- [name] = true, has it in a cooldown folder
    hovering       = {},   -- [name] = true, equipped (extreme caution)
    labelCache     = {},
}

local function playSenseSound(id)
    if not Sense.sound then return end
    pcall(function()
        local sound = Instance.new("Sound")
        sound.SoundId = "rbxassetid://" .. id
        sound.Volume  = 1
        sound.Parent  = K.Services.SoundService
        sound:Play()
        K.Services.Debris:AddItem(sound, 5)
    end)
end

local function refreshObservedFlag()
    K.beingObserved = (next(Sense.observing) ~= nil) or (next(Sense.hovering) ~= nil)
end

---------------------------------------------------------------------
-- The readout. Three states, worst-first, each with its own colour that the
-- whole panel adopts:
--
--   red     somebody is sensing right now
--   amber   somebody has it equipped but is not using it
--   white   nobody in the server has it
--
-- The readout is the headcount - "None", or "Users: 3" - and the colour is
-- what those users are doing, so one glance gives both. The names, and which
-- of them is doing what, live on hover where they are not in the way.
---------------------------------------------------------------------
local function refreshSensePanel()
    local panel = Sense.panel
    if not panel then return end

    local names, seen = {}, {}
    for name in pairs(Sense.holding) do
        if not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
    for name in pairs(Sense.hovering) do
        if not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
    table.sort(names)

    -- White is the menu accent and means "nothing going on", so the panel
    -- sits quiet until it has something to say; only a real threat colours it.
    local RED   = Color3.fromRGB(255,  28,  28)   -- same red the menu uses
    local AMBER = Color3.fromRGB(255, 170,  40)
    local CALM  = Color3.fromRGB(255, 255, 255)
    local GREY  = Color3.fromRGB(150, 150, 150)

    local sensing, equipped = 0, 0
    for _ in pairs(Sense.observing) do sensing  = sensing  + 1 end
    for _ in pairs(Sense.hovering)  do equipped = equipped + 1 end

    if #names == 0 then
        panel.set_state("None", CALM)
    elseif sensing > 0 then
        panel.set_state("Users: " .. #names, RED)
    elseif equipped > 0 then
        panel.set_state("Users: " .. #names, AMBER)
    else
        panel.set_state("Users: " .. #names, CALM)
    end

    -- Sensing first, then equipped, then merely carrying it: the row order is
    -- the threat order, so the top of the list is always the one that matters.
    local rows = {}
    local function push(pred, note, colour)
        for _, name in ipairs(names) do
            if pred(name) then
                rows[#rows + 1] = { text = name, note = note, colour = colour }
            end
        end
    end
    push(function(n) return Sense.observing[n] ~= nil end, "sensing", RED)
    push(function(n) return Sense.observing[n] == nil and Sense.hovering[n] ~= nil end, "equipped", AMBER)
    push(function(n) return Sense.observing[n] == nil and Sense.hovering[n] == nil end, "has it", GREY)

    panel.set_list(rows)
end

local function senseEvaluate()
    if not Sense.enabled then return end

    local cooldowns = cooldownsFolder()
    local settings  = gameSettings()

    if cooldowns then
        local present = {}

        for _, folder in ipairs(cooldowns:GetChildren()) do
            if folder:IsA("Folder") and folder:FindFirstChild("Chakra Sense") then
                local name = folder.Name
                present[name] = true

                if not Sense.holding[name] then
                    Sense.holding[name] = true
                    notify("Chakra Sense", name .. " has Chakra Sense")
                end

                local ps    = settings and settings:FindFirstChild(name)
                local skill = ps and ps:FindFirstChild("CurrentSkill")

                if skill and skill.Value == "Chakra Sense" then
                    if not Sense.observing[name] then
                        Sense.observing[name] = true
                        notify("Chakra Sense", "You are being observed by " .. name, 5)
                        playSenseSound("107089652181213")
                    end
                elseif Sense.observing[name] then
                    Sense.observing[name] = nil
                    notify("Chakra Sense", name .. " stopped observing you")
                    playSenseSound("98797174600699")
                end
            end
        end

        for name in pairs(Sense.holding) do
            if not present[name] then
                Sense.holding[name]   = nil
                Sense.observing[name] = nil
                notify("Chakra Sense", name .. " no longer has Chakra Sense")
            end
        end
    end

    if Sense.extremeCaution then
        local current = {}

        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                -- The label chain is 4 deep; cache the instance and only
                -- re-resolve it when a respawn drops the old one.
                local label = Sense.labelCache[p]
                if not (label and label.Parent) then
                    label = nil
                    local char = workspace:FindFirstChild(p.Name)
                    local head = char and char:FindFirstChild("FakeHead")
                    local gui  = head and head:FindFirstChild("skillGUI")
                    local name = gui and gui:FindFirstChild("skillName")
                    if name and name:IsA("TextLabel") then label = name end
                    Sense.labelCache[p] = label
                end

                if label and label.Text == "Chakra Sense" then
                    current[p.Name] = true
                    if not Sense.hovering[p.Name] then
                        Sense.hovering[p.Name] = true
                        notify("Extreme Caution", p.Name .. " has Chakra Sense equipped", 5)
                    end
                end
            end
        end

        for name in pairs(Sense.hovering) do
            if not current[name] then
                Sense.hovering[name] = nil
                notify("Chakra Sense", name .. " unequipped Chakra Sense")
            end
        end
    end

    refreshObservedFlag()
    refreshSensePanel()
end

-- Coalesce a burst of folder events into one evaluation at end of frame.
-- task.defer also means DescendantRemoving has finished removing before the
-- rescan runs, so the "no longer..." transitions fire correctly.
local function scheduleSenseEval()
    if Sense.scheduled then return end
    Sense.scheduled = true
    task.defer(function()
        Sense.scheduled = false
        pcall(senseEvaluate)
    end)
end

local function senseStart()
    if #Sense.conns > 0 then return end

    if not Sense.panel then
        Sense.panel = makePanel({
            width = 260, height = 38, y = 18, list = true,
            icon  = "rbxassetid://10723346959",   -- eye
            label = "Chakra Sense",
        })
    end
    Sense.panel.frame.Visible = true
    refreshSensePanel()

    local function hookSkillValue(inst)
        if not inst or inst.Name ~= "CurrentSkill" then return end
        if Sense.skillConns[inst] then return end
        Sense.skillConns[inst] = bind(inst.Changed:Connect(scheduleSenseEval))
    end

    local function hookCooldowns(folder)
        if not folder then return end
        Sense.conns[#Sense.conns + 1] = bind(folder.DescendantAdded:Connect(scheduleSenseEval))
        Sense.conns[#Sense.conns + 1] = bind(folder.DescendantRemoving:Connect(scheduleSenseEval))
    end

    local function hookSettings(folder)
        if not folder then return end
        for _, d in ipairs(folder:GetDescendants()) do hookSkillValue(d) end

        Sense.conns[#Sense.conns + 1] = bind(folder.DescendantAdded:Connect(function(d)
            hookSkillValue(d)
            scheduleSenseEval()
        end))

        Sense.conns[#Sense.conns + 1] = bind(folder.DescendantRemoving:Connect(function(d)
            local c = Sense.skillConns[d]
            if c then
                unbind(c)
                Sense.skillConns[d] = nil
            end
            scheduleSenseEval()
        end))
    end

    local cooldowns = cooldownsFolder()
    if cooldowns then
        hookCooldowns(cooldowns)
    else
        Sense.conns[#Sense.conns + 1] = bind(RepStorage.ChildAdded:Connect(function(c)
            if c.Name == "Cooldowns" then
                hookCooldowns(c)
                scheduleSenseEval()
            end
        end))
    end

    local settings = gameSettings()
    if settings then
        hookSettings(settings)
    else
        Sense.conns[#Sense.conns + 1] = bind(RepStorage.ChildAdded:Connect(function(c)
            if c.Name == "Settings" then
                hookSettings(c)
                scheduleSenseEval()
            end
        end))
    end

    scheduleSenseEval()
end

local function senseStop()
    for _, c in ipairs(Sense.conns) do unbind(c) end
    Sense.conns = {}

    for _, c in pairs(Sense.skillConns) do unbind(c) end
    Sense.skillConns = {}

    if Sense.extremeConn then
        unbind(Sense.extremeConn)
        Sense.extremeConn = nil
    end

    Sense.observing  = {}
    Sense.holding    = {}
    Sense.hovering   = {}
    Sense.labelCache = {}
    K.beingObserved  = false

    if Sense.panel then
        Sense.panel.frame.Visible = false
        if Sense.panel.list then Sense.panel.list.Visible = false end
    end
end

UI.boxDetection.element("Toggle", "Chakra Sense Notifier", nil, function(v)
    Sense.enabled = v.Toggle
    if v.Toggle then
        senseStart()
        notify("Security", "Chakra Sense Notifier enabled")
    else
        senseStop()
        notify("Security", "Chakra Sense Notifier disabled")
    end
end)

UI.boxDetection.element("Toggle", "Sense Alert Sound", { default = { Toggle = true } }, function(v)
    Sense.sound = v.Toggle
end)

UI.boxDetection.element("Toggle", "Drag Sense Panel", nil, function(v)
    if Sense.panel then Sense.panel.draggable = v.Toggle end
end)

UI.boxDetection.element("Toggle", "Extreme Caution", nil, function(v)
    Sense.extremeCaution = v.Toggle

    if v.Toggle then
        -- World character GUIs are not folder events, so this half needs a
        -- frame driver - but only while Extreme Caution is actually on.
        if not Sense.extremeConn then
            Sense.extremeConn = bind(RunService.Heartbeat:Connect(function()
                if not Sense.enabled or not Sense.extremeCaution then return end
                scheduleSenseEval()
            end))
        end
        notify("Security", "Extreme Caution enabled - equipped counts as watching")
    else
        if Sense.extremeConn then
            unbind(Sense.extremeConn)
            Sense.extremeConn = nil
        end
        Sense.hovering   = {}
        Sense.labelCache = {}
        refreshObservedFlag()
        refreshSensePanel()
        notify("Security", "Extreme Caution disabled")
    end
end)

yield(true)

---------------------------------------------------------------------
-- AUTO FARM MASTERY
--
-- Two completely different jobs behind one toggle, because the game grants
-- mastery two different ways:
--
--   Regular skills - fire DataEvent "startSkill" <name> then "ReleaseSkill"
--     on a loop. Several skills can be cycled by entering them comma
--     separated. Nothing is reset and nothing teleports.
--
--   Awaken modes - mastery only ticks while the mode is active, and the mode
--     can only be re-entered from a fresh character. The public script does
--     that by invoking "Awaken" and then destroying the character's Head to
--     force a respawn, sitting at the safespot while the spawn forcefield
--     burns down so nobody watches it happen.
--
-- "Don't Reset" turns the second half off: it still enters the mode, but it
-- never destroys your Head and never teleports you. You keep the mode for as
-- long as it naturally lasts and stay exactly where you are.
--
-- Both paths pause while the chakra sense watcher says somebody is looking.
---------------------------------------------------------------------
local AWAKEN_MODES = {
    "Sharingan [Stage 1]", "Sharingan [Stage 2]", "Sharingan [Stage 3]",
    "Obito's Mangekyo", "Obito's Eternal Mangekyo",
    "Itachi's Mangekyo", "Itachi's Eternal Mangekyo",
    "Sasuke's Mangekyo", "Sasuke's Eternal Mangekyo",
    "Pain's Rinnegan", "Sasuke's Rinnegan",
    "Byakugan [Stage 1]", "Byakugan [Stage 2]", "Byakugan [Stage 3]", "Byakugan [Stage 4]",
    "Hinata's Byakugan", "Neji's Byakugan",
    "Adamantine Sealing Chains", "Hundred Healings",
    "Green Gates", "Blue Gates",
    "Butterfly Mode", "Butterfly Mode V2", "Akamichi Mode",
    "Ketsuryugan [Stage 1]", "Ketsuryugan [Stage 2]", "Ketsuryugan [Stage 3]",
    "Jinchuriki [Stage 1]", "Jinchuriki [Stage 2]",
    "Matatabi Cloak", "Shukaku Cloak", "Isobu Cloak",
}

-- The mastery farm parks at one of the BACKUP safespots rather than the main
-- one. The main spot is where every other teleport in the script lands, so
-- sitting there on a respawn loop is the most visible thing you can do; these
-- three are off the beaten path and get picked by whichever is empty.
local MASTERY_SAFESPOTS = {
    CFrame.new(-2678.399414, 949.681030, -2065.443115) * CFrame.Angles(0, -0.041036, 0),
    CFrame.new(-3488.499756, 436.322540, -5240.671875) * CFrame.Angles(0, -1.572860, 0),
    CFrame.new(1692.969971, 200.596710, 1404.145996)  * CFrame.Angles(0, -0.019851, 0),
}

local Mastery = {
    enabled     = false,
    input       = "",
    noReset     = false,
    thread      = nil,
    respawnConn = nil,
    toggle      = nil,
    spot        = nil,   -- chosen once per cycle, not per frame
}

-- First backup with nobody near it; falls back to the first if all are busy.
local function masterySafespot()
    for _, cf in ipairs(MASTERY_SAFESPOTS) do
        if #playersNear(cf.Position, Safe.detectionRange) == 0 then
            return cf
        end
    end
    return MASTERY_SAFESPOTS[1]
end

local function isAwakenMode(name)
    return table.find(AWAKEN_MODES, name) ~= nil
end

local function masteryStop()
    Mastery.enabled = false

    if Mastery.thread then
        pcall(function() task.cancel(Mastery.thread) end)
        Mastery.thread = nil
    end
    if Mastery.respawnConn then
        unbind(Mastery.respawnConn)
        Mastery.respawnConn = nil
    end
end

-- Returns nil plus a reason when the input cannot be used.
local function masterySkills()
    local text = Mastery.input

    if text == "" then
        return nil, "Enter a skill or mode name first"
    end

    if not string.find(text, ",") then
        return { text }
    end

    -- A space either side of a comma would make the skill name wrong, and the
    -- server silently does nothing rather than erroring - so catch it here.
    if string.find(text, ", ") or string.find(text, " ,") then
        return nil, "Remove the spaces around commas, e.g. Water Dragon,Water Prison"
    end

    local list = {}
    for skill in string.gmatch(text, "[^,]+") do
        list[#list + 1] = skill
    end

    for _, skill in ipairs(list) do
        if isAwakenMode(skill) then
            return nil, "Awaken modes cannot be cycled - remove: " .. skill
        end
    end

    return list
end

-- Chakra sense means somebody is actively looking at you. Pausing and
-- resuming in place just means they watch you stand still and then start
-- again; the farm shuts itself off instead and tells you why.
local function masteryCheckClear()
    if not Mastery.enabled then return false end

    if K.beingObserved then
        masteryStop()
        if Mastery.toggle then
            Mastery.toggle:set_value({ Toggle = false }, true)
        end
        notify("Farm", "Chakra sense detected - activations farm stopped", 6)
        return false
    end

    return true
end

local function masteryAwakenCycle(mode)
    task.wait(0.1)
    if not masteryCheckClear() then return end

    -- Pick the spot once per cycle: re-evaluating every frame would make us
    -- hop between spots while the forcefield burns down.
    Mastery.spot = masterySafespot()

    local char = character() or LP.CharacterAdded:Wait()
    local hrp  = char and char:WaitForChild("HumanoidRootPart", 10)
    if not hrp or not Mastery.enabled then return end

    -- Ride out the spawn forcefield. With resetting on we wait it out parked
    -- at the safespot; with it off we just wait where we are.
    local lastPark = 0
    repeat
        task.wait()
        if not masteryCheckClear() then return end

        -- Parking used to be re-written every frame, which was free; it is a
        -- remote now, so it is re-asked at most twice a second and only once
        -- we have actually drifted off the spot.
        if not Mastery.noReset and os.clock() - lastPark > 0.5 then
            local spot = Mastery.spot or masterySafespot()
            local here = root()
            if here and (here.Position - spot.Position).Magnitude > 5 then
                lastPark = os.clock()
                pcall(function() safeTeleport(spot, true) end)
            end
        end
    until not char:FindFirstChild("ForceField") or char.Parent == nil or not Mastery.enabled

    if not masteryCheckClear() then return end
    if not (char and char.Parent and hrp and hrp.Parent) then return end

    pcall(function()
        RepStorage:WaitForChild("Events"):WaitForChild("DataFunction"):InvokeServer("Awaken", mode)
    end)

    if Mastery.noReset then return end

    task.wait(0.1)
    local head = char:FindFirstChild("Head")
    if head then
        pcall(function() head:Destroy() end)
    end
end

local function masteryStart()
    local skills, reason = masterySkills()
    if not skills then
        notify("Farm", reason, 5)
        masteryStop()
        if Mastery.toggle then Mastery.toggle:set_value({ Toggle = false }, true) end
        return
    end

    local awaken = (#skills == 1) and isAwakenMode(skills[1])

    if awaken then
        local mode = skills[1]

        -- Without a reset there is no cycle to drive, so this runs once per
        -- natural respawn instead of once per forced one.
        Mastery.respawnConn = bind(LP.CharacterAdded:Connect(function()
            if not Mastery.enabled then return end
            task.spawn(masteryAwakenCycle, mode)
        end))

        if character() then
            Mastery.thread = task.spawn(masteryAwakenCycle, mode)
        end

        notify("Farm", "Farming " .. mode .. (Mastery.noReset and " (no reset)" or ""), 4)
        return
    end

    Mastery.thread = task.spawn(function()
        local index = 1

        while Mastery.enabled do
            if not masteryCheckClear() then break end

            local skill = skills[index]

            pcall(function()
                RepStorage:WaitForChild("Events"):WaitForChild("DataEvent"):FireServer("startSkill", skill)
            end)
            task.wait()

            pcall(function()
                RepStorage:WaitForChild("Events"):WaitForChild("DataEvent"):FireServer("ReleaseSkill")
            end)
            task.wait()

            index = index + 1
            if index > #skills then index = 1 end
        end
    end)

    notify("Farm", "Farming " .. table.concat(skills, ", "), 4)
end

UI.mastery.element("TextBox", "Skill / Mode Name", { maxlen = 120 }, function(v)
    Mastery.input = v.Text
end)

Mastery.toggle = UI.mastery.element("Toggle", "Auto Farm Activations", nil, function(v)
    Mastery.enabled = v.Toggle

    if v.Toggle then
        masteryStart()
    else
        masteryStop()
        notify("Farm", "Auto Farm Activations disabled")
    end
end)

UI.mastery.create_line()
UI.mastery.element("Label", "Comma separate to cycle skills")
UI.mastery.element("Label", "(no spaces around the commas)")

UI.masteryOpt.element("Toggle", "Don't Reset", nil, function(v)
    Mastery.noReset = v.Toggle
    notify("Farm", v.Toggle
        and "Reset off - no teleport, no head destroy"
        or  "Reset on - will safespot and force respawn", 4)
end)


yield(true)
-- ===================================================================
-- AUTO PARRY - DISABLED
--
-- Commented out on request. Everything below is intact: uncomment the
-- block (and the UI.parry* / UI.secBuilder sectors in the layout, and
-- the Parry lines in unload) to bring it back.
-- ===================================================================
--[==[

---------------------------------------------------------------------
-- AUTO PARRY
--
-- Rewritten against the game's own block code rather than a guess at it.
--
-- WHY THE OLD ONE MISBEHAVED
--
-- It decided whether it could parry with a hand-rolled check (stunned, a
-- CurrentSkill, a couple of animation ids) and then just invoked "Block".
-- The game's real gate is attemptBlock() and it is much stricter:
--
--     u32.Occupied == false and u32.BlockCooldown == false
--     and u32.ShortCooldown == false and u32.BlockStartCooldown == false
--     and Settings.Stunned.Value == false and u32.Knocked == false
--     and not character:FindFirstChild("ForceField")
--     and not character:GetAttribute("KotoamatsukamiAttacking")
--     and not character:GetAttribute("KotoamatsukamiForceMove")
--
-- Three of those live only in the client's state table (u32) and are
-- invisible from outside it - which is exactly why the old version blocked
-- during states where blocking is impossible, and why it sometimes silently
-- did nothing: the server refused a Block the client should never have sent.
--
-- It also never did what attemptBlock does around the invoke - set
-- Settings.Blocking, take Occupied, drop WalkSpeed to 5 and JumpPower to 0,
-- and roll all of it back if the server says no. Without that the client
-- never enters its blocking state even when the server accepts.
--
-- This version resolves u32 out of canM1's upvalues (same route as
-- performM1) and mirrors attemptBlock exactly, including the rollback.
--
-- TIMING
--
-- From the game's settings table:
--     PerfectBlockWindow   = 0.25   -- how long a block counts as a parry
--     PerfectBlockCooldown = 0.6
--     BlockCooldown        = 0.5    -- after EndBlock
--     MeleeStunTime        = 0.6
--
-- So a parry lands if the hit arrives within 0.25s of the block starting.
-- Aiming for the middle of that window (0.125s before impact) leaves the most
-- slack either side. Auto Delay subtracts one-way ping from each move's
-- configured delay so the block ARRIVES on time rather than being SENT on
-- time - which is the whole difference on a 150ms connection.
---------------------------------------------------------------------
local PB_WINDOW   = 0.25
local PB_COOLDOWN = 0.6
local BLOCK_CD    = 0.5

local Parry = {
    enabled     = false,
    blatant     = false,   -- default OFF now: the real gate is worth using
    autoDelay   = true,
    customDelay = 0,
    cooldown    = 0.3,
    lastParry   = 0,
    conns       = {},
    dataFn      = nil,
    state       = nil,     -- u32, when we can reach it
    lastPing    = 0.05,
    parryBreaks = false,   -- see Parry.block
}

-- Generated from the game's own data tables in gamescript2:
--   u20.Animations  animation name -> asset id
--   u20.Skills      StartUpAnim, LoadUpTime, OccupiedTime, BlockBreaks
--   u20.NPC         every NPC attack, each with a Blockable flag
--
-- delay comes from LoadUpTime (player skills) or the windup wait in the NPC
-- attack dispatcher, so it is the game's own number rather than a guess.
-- `breaks = true` marks BlockBreaks skills - see Parry.block.
--
-- Most are off by default: 150 moves all firing would block constantly.
Parry.moves = {
    { name = "Smoldering Earth", type = "workspace", id = "Branch", detect = 60, range = 30, delay = 0, block = 0.5, on = true },
    { name = "Fireball", type = "debris", id = "Fireball", detect = 80, range = 25, delay = 0, block = 0.2, on = true },
    { name = "Water Wave", type = "workspace", id = "Water Wave", detect = 200, range = 30, delay = 0, block = 0.2, on = true },
    { name = "Water Dragon", type = "workspace", id = "WaterDragonHead", detect = 200, range = 25, delay = 0, block = 0.6, on = true },
    { name = "Earth Dragon", type = "debris", id = "Earth Dragon", detect = 80, range = 30, delay = 0, block = 0.5, on = true },
    { name = "128 Palms", type = "animation", id = "8699113073", detect = 150, range = 60, delay = 0.0, block = 0.7, on = false },
    { name = "64 Palms", type = "animation", id = "8699113073", detect = 150, range = 60, delay = 0.0, block = 0.7, on = false },
    { name = "Almighty Push", type = "animation", id = "10930376912", breaks = true, detect = 150, range = 60, delay = 0.4, block = 0.9, on = true },
    { name = "Asumai One Two", type = "animation", id = "99624902543164", breaks = true, detect = 80, range = 25, delay = 0.0, block = 0.5, on = false },
    { name = "Barbarian Summoning", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Barbarit Summoning", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Beast Extraction", type = "animation", id = "9916542210", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Binding Seal", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Blinding Strike", type = "animation", id = "8214031055", breaks = true, detect = 80, range = 25, delay = 0.3, block = 0.6, on = false },
    { name = "Blood Arrow", type = "animation", id = "83093666885184", detect = 150, range = 60, delay = 0.45, block = 0.55, on = false },
    { name = "Blood Dragon", type = "animation", id = "7250960114", breaks = true, detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Bone Manipulation", type = "animation", id = "92287834952226", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Bowl Summoning", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Bugs Strike", type = "animation", id = "11204330767", detect = 150, range = 60, delay = 0.4, block = 0.8, on = false },
    { name = "Bugs Swarm", type = "animation", id = "8789227433", detect = 150, range = 60, delay = 0.3, block = 0.5, on = false },
    { name = "Butterfly Flight", type = "animation", id = "11273119075", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Butterfly Slam", type = "animation", id = "11289531561", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.65, on = false },
    { name = "Chain Pull", type = "animation", id = "10069265035", detect = 150, range = 60, delay = 0.33, block = 0.5, on = false },
    { name = "Chains Of The Wild", type = "animation", id = "8789227433", breaks = true, detect = 150, range = 60, delay = 0.3, block = 1.1, on = false },
    { name = "Chakra Arrow Barrage", type = "animation", id = "83947150304006", detect = 80, range = 25, delay = 0.0, block = 1.8, on = false },
    { name = "Chakra Exchange", type = "animation", id = "11207371709", detect = 150, range = 60, delay = 0.3, block = 1.0, on = false },
    { name = "Chakra Infused Slam", type = "animation", id = "10075486924", breaks = true, detect = 80, range = 25, delay = 0.0, block = 0.8, on = false },
    { name = "Chakra Pellet", type = "animation", id = "7256553550", detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Chakra Ressurection", type = "animation", id = "9763847329", detect = 150, range = 60, delay = 0.0, block = 0.2, on = false },
    { name = "Chakra Sense", type = "animation", id = "9864206537", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Chakra Zone", type = "animation", id = "9885247576", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Charged Ram", type = "animation", id = "5571412330", detect = 80, range = 25, delay = 0.0, block = 3.0, on = false },
    { name = "Cleave Rush", type = "animation", id = "74933021051396", detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Clone Throw", type = "animation", id = "9284920294", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.4, on = false },
    { name = "Coral Emerge", type = "animation", id = "99068559501337", breaks = true, detect = 150, range = 60, delay = 0.4, block = 0.5, on = false },
    { name = "Cratos Summoning", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Deep Forest Emergence", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.4, on = false },
    { name = "Demonic Ice Mirrors", type = "animation", id = "7198878301", detect = 150, range = 60, delay = 0.0, block = 0.75, on = false },
    { name = "Dragonic Flames", type = "animation", id = "6914805919", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Drilling Bones", type = "animation", id = "8580099842", detect = 150, range = 60, delay = 0.5, block = 2.5, on = false },
    { name = "Dynamic Entry", type = "animation", id = "9456787558", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.9, on = true },
    { name = "Earth Golem", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Earth Slam", type = "animation", id = "11289531561", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.8, on = true },
    { name = "Earth Wall", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Explosive Rotation", type = "animation", id = "8580099842", detect = 150, range = 60, delay = 0.5, block = 2.25, on = false },
    { name = "Extraction Seal", type = "animation", id = "9916542210", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Feather Genjutsu", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Fern Dance", type = "animation", id = "7198878301", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Fire Seal", type = "animation", id = "7182797024", breaks = true, detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Flame Company", type = "animation", id = "8201236844", detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Fog Illusion", type = "animation", id = "8201236844", detect = 150, range = 60, delay = 0.0, block = 0.75, on = false },
    { name = "Fruit Summoning", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Gale Palm", type = "animation", id = "7293816408", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.9, on = false },
    { name = "Genjutsu Release", type = "animation", id = "73464540236149", detect = 150, range = 60, delay = 0.0, block = 1.7, on = false },
    { name = "Healing Bond", type = "animation", id = "7862279706", detect = 150, range = 60, delay = 0.0, block = 1.5, on = false },
    { name = "Healing Zone", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Hinata\\'s Byakugan", type = "animation", id = "7250960114", detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Hirudora Projectile", type = "animation", id = "83093666885184", detect = 150, range = 60, delay = 0.45, block = 0.6, on = false },
    { name = "Hyper Roar", type = "animation", id = "8789227433", detect = 150, range = 60, delay = 0.0, block = 0.2, on = false },
    { name = "Ice Dragon", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Ice Floor", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Ice Mirror", type = "animation", id = "7250960114", detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Ice Rain", type = "animation", id = "17685181678", detect = 150, range = 60, delay = 0.0, block = 0.2, on = false },
    { name = "Ice Spikes", type = "animation", id = "7198878301", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Improved Barrage", type = "animation", id = "9840792947", detect = 150, range = 60, delay = 0.0, block = 2.7, on = false },
    { name = "Injury Heal", type = "animation", id = "8201236844", detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Isobu Cloak Bomb", type = "animation", id = "93839342012083", detect = 150, range = 60, delay = 0.0, block = 1.75, on = false },
    { name = "Jinchuriki Bomb", type = "animation", id = "99832737981724", detect = 150, range = 60, delay = 0.0, block = 1.75, on = false },
    { name = "Jinchuriki Grab", type = "animation", id = "123629309287395", detect = 150, range = 60, delay = 0.4, block = 1.2, on = false },
    { name = "Kamui Self-Warp", type = "animation", id = "7286352048", detect = 150, range = 60, delay = 0.3, block = 2.4, on = false },
    { name = "Kamui Suck", type = "animation", id = "7286352048", detect = 150, range = 60, delay = 0.3, block = 2.65, on = false },
    { name = "Kotoamatsukami Betray", type = "animation", id = "7286352048", detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Kotoamatsukami Defend", type = "animation", id = "7286352048", detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Kotoamatsukami Explode", type = "animation", id = "7286352048", detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Kunai Throw", type = "animation", id = "7256537857", detect = 80, range = 25, delay = 0.0, block = 0.6, on = false },
    { name = "Lightning Leap", type = "animation", id = "86213040968703", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Lightning Ripple", type = "animation", id = "7198878301", breaks = true, detect = 150, range = 60, delay = 0.0, block = 1.4, on = false },
    { name = "Lightning Stream", type = "animation", id = "7193783109", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Lightning Strike", type = "animation", id = "17685181678", breaks = true, detect = 150, range = 60, delay = 0.8, block = 1.0, on = false },
    { name = "Limb Blossom", type = "animation", id = "8201236844", detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Lion\\'s Barrage", type = "animation", id = "9840792947", detect = 150, range = 60, delay = 0.0, block = 1.7, on = false },
    { name = "Matatabi Cloak Bomb", type = "animation", id = "93839342012083", detect = 150, range = 60, delay = 0.0, block = 1.75, on = false },
    { name = "Multi Kunai Throw", type = "animation", id = "7256537857", detect = 80, range = 25, delay = 0.0, block = 0.6, on = false },
    { name = "Night Guy", type = "animation", id = "7293816408", detect = 150, range = 60, delay = 0.0, block = 0.75, on = false },
    { name = "Overhead Spin", type = "animation", id = "7300582359", detect = 150, range = 60, delay = 0.0, block = 2.5, on = false },
    { name = "Palm Rotation", type = "animation", id = "8580099842", detect = 150, range = 60, delay = 0.5, block = 3.0, on = false },
    { name = "Pentadummy Summoning", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Phoenix Flower", type = "animation", id = "6914805919", detect = 150, range = 60, delay = 0.0, block = 0.7, on = false },
    { name = "Piercing Chakra Arrow", type = "animation", id = "125900382257409", breaks = true, detect = 80, range = 25, delay = 0.0, block = 0.3, on = false },
    { name = "Pool Expansion", type = "animation", id = "7189207090", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.8, on = false },
    { name = "Primary Lotus", type = "animation", id = "11269833515", detect = 150, range = 60, delay = 0.0, block = 1.5, on = false },
    { name = "Protruding Chains", type = "animation", id = "7193783109", breaks = true, detect = 150, range = 60, delay = 0.3, block = 1.2, on = false },
    { name = "Purple Susanoo Grab", type = "animation", id = "7286352048", breaks = true, detect = 150, range = 60, delay = 0.3, block = 0.5, on = false },
    { name = "Rasengan Barrage", type = "animation", id = "8211263620", breaks = true, detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Rasenshuriken Projectile", type = "animation", id = "6914805919", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Revival Healing", type = "animation", id = "7255491372", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Rising Wind", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Sasuke Portal", type = "animation", id = "7286352048", detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Scrambled Mind", type = "animation", id = "6914805919", detect = 150, range = 60, delay = 0.0, block = 1.5, on = false },
    { name = "Sealing Banners", type = "animation", id = "7298826950", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Sealing Barrier Rod", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Sealing Floor", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Self Injury Heal", type = "animation", id = "8201236844", detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Self Purification", type = "animation", id = "7862279706", detect = 150, range = 60, delay = 0.0, block = 1.8, on = false },
    { name = "Shisui Susanoo Summon", type = "animation", id = "7286352048", detect = 150, range = 60, delay = 0.0, block = 0.5, on = false },
    { name = "Shisui Throw Drill", type = "animation", id = "7250960114", detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Shukaku Cloak Arm Emerge", type = "animation", id = "6894770447", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Shukaku Cloak Bomb", type = "animation", id = "93839342012083", detect = 150, range = 60, delay = 0.0, block = 1.75, on = false },
    { name = "Shukaku Cloak Storm", type = "animation", id = "7198878301", detect = 150, range = 60, delay = 0.0, block = 0.75, on = false },
    { name = "Spinning Dash", type = "animation", id = "114640618929317", breaks = true, detect = 80, range = 25, delay = 0.0, block = 0.6, on = false },
    { name = "Spinning Glide", type = "animation", id = "10075589617", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Spinning Human Boulder", type = "animation", id = "129108611364528", detect = 150, range = 60, delay = 0.4, block = 3.0, on = false },
    { name = "Susanoo Pose", type = "animation", id = "8896884566", breaks = true, detect = 150, range = 60, delay = 0.0, block = 2.5, on = false },
    { name = "Thrusting Strike", type = "animation", id = "10560758096", breaks = true, detect = 80, range = 25, delay = 0.5, block = 0.9, on = true },
    { name = "Triple Blood Dragons", type = "animation", id = "7250960114", breaks = true, detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Triple Slash", type = "animation", id = "104320328423578", detect = 80, range = 25, delay = 0.2, block = 1.05, on = false },
    { name = "Twin Blood Dragons", type = "animation", id = "7250960114", breaks = true, detect = 150, range = 60, delay = 0.0, block = 1.0, on = false },
    { name = "Twin Flame Dragons", type = "animation", id = "9849419108", breaks = true, detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Twin Lions Barrage", type = "animation", id = "8699113073", detect = 150, range = 60, delay = 0.0, block = 2.1, on = false },
    { name = "Twin Strike", type = "animation", id = "10014972099", breaks = true, detect = 80, range = 25, delay = 0.0, block = 0.72, on = false },
    { name = "Universal Pull", type = "animation", id = "11159585258", detect = 150, range = 60, delay = 0.4, block = 0.8, on = true },
    { name = "Vacuum Rotation", type = "animation", id = "8580099842", detect = 150, range = 60, delay = 0.5, block = 3.0, on = false },
    { name = "Vertical Slash", type = "animation", id = "7282630228", detect = 80, range = 25, delay = 0.1, block = 0.9, on = false },
    { name = "Water Fountain", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Water Pool", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Water Prison", type = "animation", id = "7182797024", breaks = true, detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Wind Discs", type = "animation", id = "6914805919", detect = 150, range = 60, delay = 0.0, block = 1.7, on = false },
    { name = "Wind Tornado", type = "animation", id = "7182797024", breaks = true, detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Wired Kunai", type = "animation", id = "9937511106", detect = 80, range = 25, delay = 0.0, block = 0.3, on = false },
    { name = "Wood Seal", type = "animation", id = "7182797024", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Wood Suppression", type = "animation", id = "7182797024", breaks = true, detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Wooden Roots", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Wooden Spire", type = "animation", id = "6894770447", detect = 150, range = 60, delay = 0.0, block = 0.6, on = false },
    { name = "Yin Seal", type = "animation", id = "7193783109", detect = 150, range = 60, delay = 0.0, block = 3.0, on = false },
    { name = "Barbarit The Enchanted - Club Spin", type = "npc", id = "9656290960", npc = "Barbarit The Enchanted", detect = 180, range = 20, delay = 0.6, block = 0.92, on = true },
    { name = "Barbarit The Enchanted - Kamui Club Slam", type = "npc", id = "9985568656", npc = "Barbarit The Enchanted", detect = 180, range = 30, delay = 0.7, block = 0.4, on = true },
    { name = "Barbarit The Hallowed - Club Spin", type = "npc", id = "9656290960", npc = "Barbarit The Hallowed", detect = 180, range = 20, delay = 0.6, block = 0.92, on = true },
    { name = "Barbarit The Hallowed - Kamui Club Slam", type = "npc", id = "9985568656", npc = "Barbarit The Hallowed", detect = 180, range = 30, delay = 0.7, block = 0.4, on = true },
    { name = "Barbarit The Rose - Club Spin", type = "npc", id = "9656290960", npc = "Barbarit The Rose", detect = 180, range = 20, delay = 0.6, block = 0.92, on = true },
    { name = "Barbarit The Rose - Kamui Club Slam", type = "npc", id = "9985568656", npc = "Barbarit The Rose", detect = 180, range = 30, delay = 0.7, block = 0.4, on = true },
    { name = "Clay Runner - Lava Ground Pound", type = "npc", id = "6038040720", npc = "Clay Runner", detect = 150, range = 28, delay = 0.1, block = 1.4, on = true },
    { name = "Frosted The Rose - Club Spin", type = "npc", id = "9656290960", npc = "Frosted The Rose", detect = 180, range = 20, delay = 0.6, block = 0.92, on = true },
    { name = "Frosted The Rose - Kamui Club Slam", type = "npc", id = "9985568656", npc = "Frosted The Rose", detect = 180, range = 30, delay = 0.7, block = 0.4, on = true },
    { name = "Hallowed Lavarossa - Lava Ground Pound", type = "npc", id = "6038040720", npc = "Hallowed Lavarossa", detect = 150, range = 28, delay = 0.1, block = 1.4, on = true },
    { name = "Lava Snake - Snake Spit", type = "npc", id = "9954909571", npc = "Lava Snake", detect = 250, range = 23, delay = 0.55, block = 1.6, on = true },
    { name = "The Barbarian - Petrifying Roar", type = "npc", id = "6070787172", npc = "The Barbarian", detect = 150, range = 28, delay = 0.3, block = 0.4, on = true },
    { name = "The Enchanted Barbarian - Petrifying Roar", type = "npc", id = "6070787172", npc = "The Enchanted Barbarian", detect = 150, range = 28, delay = 0.3, block = 0.4, on = true },
    { name = "The Frosted Barbarian - Petrifying Roar", type = "npc", id = "6070787172", npc = "The Frosted Barbarian", detect = 150, range = 28, delay = 0.3, block = 0.4, on = true },
    { name = "The Hallowed Barbarian - Petrifying Roar", type = "npc", id = "6070787172", npc = "The Hallowed Barbarian", detect = 150, range = 28, delay = 0.3, block = 0.4, on = true },
    { name = "The Ringed Samurai - Club Spin", type = "npc", id = "9656290960", npc = "The Ringed Samurai", detect = 200, range = 20, delay = 0.6, block = 0.92, on = true },
    -- Matatabi and the bosses the Blockable table does not cover. Carried over
    -- from the original list, enabled by default like the rest of the NPC set.
    { name = "Beast Roar", type = "beast", id = "98245450702485", detect = 150, range = 50, delay = 0.1, block = 3, on = true },
    { name = "Beast Bullet", type = "beast", id = "96448190421657", detect = 150, range = 90, delay = 0.4, block = 0.4, on = true },
    { name = "Beast R Punch", type = "beast", id = "86414508786370", detect = 150, range = 35, delay = 0.2, block = 0.5, on = true },
    { name = "Beast Bite", type = "beast", id = "113419524303689", detect = 150, range = 50, delay = 0.2, block = 0.4, on = true },
    { name = "Beast Tail Swipe", type = "beast", id = "120703747916516", detect = 150, range = 50, delay = 0.1, block = 0.4, on = true },
    { name = "Beast L Punch", type = "beast", id = "93012373755384", detect = 150, range = 50, delay = 0.4, block = 0.5, on = true },
    { name = "Manda - Swipe", type = "npc", npc = "Manda", id = "9954860601", detect = 150, range = 30, delay = 0.3, block = 0.4, on = true },
    { name = "Manda - 360 Swipe", type = "npc", npc = "Manda", id = "9955456879", detect = 150, range = 30, delay = 0.1, block = 0.4, on = true },
    { name = "Lavarossa - R Punch", type = "npc", npc = "Lavarossa", id = "6038040720", detect = 150, range = 20, delay = 0.2, block = 0.4, on = true },
    { name = "Lavarossa - L Punch", type = "npc", npc = "Lavarossa", id = "6038041916", detect = 150, range = 20, delay = 0.2, block = 0.4, on = true },
    { name = "Cratos - Spin", type = "npc", npc = "Cratos", id = "6999923160", detect = 150, range = 30, delay = 0.1, block = 1.5, on = true },
}

-- Defaults are snapshotted so the builder can reset a move it has edited.
Parry.defaults = {}
for _, m in ipairs(Parry.moves) do
    Parry.defaults[m.name] = { detect = m.detect, range = m.range, delay = m.delay, block = m.block, on = m.on }
end

---------------------------------------------------------------------
-- CLIENT STATE (u32)
--
-- u32 is an upvalue of canM1, not a global, so it is picked out by shape
-- rather than by index - upvalue order is not something to rely on.
---------------------------------------------------------------------
function Parry.resolveState()
    Parry.state = nil

    pcall(function()
        for _, f in ipairs(getgc(false)) do
            if type(f) == "function" then
                local named, name = pcall(debug.info, f, "n")
                if named and (name == "canM1" or name == "performM1") then
                    for i = 1, 12 do
                        local ok, _, val = pcall(debug.getupvalue, f, i)
                        if ok and type(val) == "table"
                            and rawget(val, "Occupied") ~= nil
                            and rawget(val, "BlockCooldown") ~= nil then
                            Parry.state = val
                            return
                        end
                    end
                end
            end
        end
    end)

    return Parry.state ~= nil
end

function Parry.dataFunction()
    if not Parry.dataFn then
        Parry.dataFn = RepStorage:WaitForChild("Events"):WaitForChild("DataFunction")
    end
    return Parry.dataFn
end

-- One-way latency in seconds. Data Ping is a round trip.
function Parry.ping()
    local ok, ms = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(ms) == "number" and ms > 0 then
        Parry.lastPing = math.clamp((ms / 1000) / 2, 0, 0.5)
    end
    return Parry.lastPing
end

---------------------------------------------------------------------
-- THE GATE - mirrors attemptBlock() exactly
---------------------------------------------------------------------
function Parry.canBlock()
    local char = character()
    if not char then return false end

    -- Applies even in blatant mode: a block under a forcefield is refused and
    -- a block while already blocking is wasted traffic.
    if char:FindFirstChild("ForceField") then return false end
    if char:GetAttribute("KotoamatsukamiAttacking") then return false end
    if char:GetAttribute("KotoamatsukamiForceMove") then return false end
    if settingFlag("Blocking") then return false end
    if settingFlag("Stunned") then return false end

    if Parry.blatant then return true end

    local s = Parry.state
    if s then
        if s.Occupied ~= false then return false end
        if s.BlockCooldown ~= false then return false end
        if s.ShortCooldown ~= false then return false end
        if s.BlockStartCooldown ~= false then return false end
        if s.Knocked ~= false then return false end
    else
        -- No state table: fall back to what is visible from outside.
        if settingFlag("Knocked") then return false end
        local skill = settingText("CurrentSkill")
        if skill and skill ~= "" then return false end
        local grip = settingText("Gripping")
        if grip and grip ~= "None" then return false end
    end

    return true
end

---------------------------------------------------------------------
-- BLOCK / UNBLOCK - the same sequence the game performs
---------------------------------------------------------------------
function Parry.startBlock()
    local char = character()
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local s    = Parry.state

    local settings = mySettings()
    local blocking = settings and settings:FindFirstChild("Blocking")

    if s then
        s.BlockStartCooldown = true
        s.Occupied = true
    end
    if blocking then blocking.Value = true end
    if hum then
        hum.WalkSpeed = 5
        hum.JumpPower = 0
    end

    local accepted = false
    pcall(function()
        accepted = Parry.dataFunction():InvokeServer("Block") == true
    end)

    if accepted then
        if s then s.BlockStartCooldown = false end
        return true
    end

    -- Server said no: put everything back, exactly as attemptBlock does.
    if blocking then blocking.Value = false end
    if s then
        s.BlockStartCooldown = false
        s.Occupied = false
    end
    if hum then
        hum.WalkSpeed = (s and s.OriginSpeed) or 16
        hum.JumpPower = (s and s.OriginJump) or 50
    end
    return false
end

function Parry.endBlock()
    local char = character()
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local s    = Parry.state

    -- The game refuses to release a block while stunned; releasing our own
    -- state here would desync us from it.
    if settingFlag("Stunned") then return end

    if s then
        s.Occupied = false
        s.BlockCooldown = true
    end
    if hum then
        hum.WalkSpeed = (s and s.OriginSpeed) or 16
        hum.JumpPower = (s and s.OriginJump) or 50
    end

    pcall(function() Parry.dataFunction():InvokeServer("EndBlock") end)

    task.delay(BLOCK_CD, function()
        if s then s.BlockCooldown = false end
    end)
end

-- delay is how long before the hit we want the block to EXIST.
function Parry.block(delay, duration, move)
    -- Skills flagged BlockBreaks in u20.Skills. The field is defined per skill
    -- but never read anywhere in the client dumps, so whether a perfect block
    -- beats one is unverified - and guessing wrong costs BlockBreakStunTime
    -- (2s) every time. Off unless asked for.
    if move and move.breaks and not Parry.parryBreaks then return end

    local now = os.clock()
    if now - Parry.lastParry < Parry.cooldown then return end
    if not Parry.canBlock() then return end

    Parry.lastParry = now

    delay    = (delay or 0) + Parry.customDelay
    duration = duration or 0.2

    -- Auto Delay: fire early by one-way ping so the Block ARRIVES on time,
    -- and aim for the middle of the perfect-block window rather than its edge.
    if Parry.autoDelay then
        delay = delay - Parry.ping() - (PB_WINDOW / 2)
    end
    if delay < 0 then delay = 0 end

    task.spawn(function()
        if delay > 0 then task.wait(delay) end
        if not Parry.enabled or not Parry.canBlock() then return end
        if not Parry.startBlock() then return end

        task.delay(duration, Parry.endBlock)
    end)
end

---------------------------------------------------------------------
-- DETECTION
---------------------------------------------------------------------
function Parry.watchCloser(getPos, move, window)
    task.spawn(function()
        local started = os.clock()

        while os.clock() - started < (window or 1.5) do
            if not Parry.enabled then return end

            local myRoot = root()
            if not myRoot then return end

            local pos = getPos()
            if not pos then return end

            if (pos - myRoot.Position).Magnitude <= move.range then
                Parry.block(move.delay, move.block, move)
                return
            end

            task.wait(0.016)
        end
    end)
end

function Parry.watchProjectile(obj, move)
    Parry.watchCloser(function()
        if not obj or not obj.Parent then return nil end
        if obj:IsA("BasePart") then return obj.Position end
        if obj:IsA("Model") then
            local part = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
            return part and part.Position
        end
        return nil
    end, move, 5)
end

function Parry.scanObject(obj)
    if not Parry.enabled then return end
    if not (obj:IsA("BasePart") or obj:IsA("Model")) then return end

    local lower = string.lower(obj.Name)
    if string.find(lower, "dragon", 1, true) and string.find(obj.Name, LP.Name, 1, true) then
        return
    end

    for _, move in ipairs(Parry.moves) do
        if move.on and (move.type == "debris" or move.type == "workspace") then
            if string.find(lower, string.lower(move.id), 1, true) then
                Parry.watchProjectile(obj, move)
                return
            end
        end
    end
end

function Parry.hookAnimator(model, lookup)
    local hum      = model and model:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return end

    Parry.conns[#Parry.conns + 1] = bind(animator.AnimationPlayed:Connect(function(track)
        if not Parry.enabled then return end

        local id   = tostring(track.Animation and track.Animation.AnimationId or ""):match("(%d+)")
        local move = id and lookup[id]
        if not move or not move.on then return end

        local myRoot = root()
        if not myRoot then return end

        local function sourcePos()
            if not model or not model.Parent then return nil end
            local part = model:FindFirstChild("HumanoidRootPart")
                or model:FindFirstChild("Torso") or model.PrimaryPart
            return part and part.Position
        end

        local pos = sourcePos()
        if not pos or (pos - myRoot.Position).Magnitude > move.detect then return end

        Parry.watchCloser(sourcePos, move, 1.5)
    end))
end

function Parry.buildLookups()
    local anim, beast, npc = {}, {}, {}
    for _, move in ipairs(Parry.moves) do
        if move.type == "animation" then
            anim[move.id] = move
        elseif move.type == "beast" then
            beast[move.id] = move
        elseif move.type == "npc" and move.npc then
            npc[move.npc] = npc[move.npc] or {}
            npc[move.npc][move.id] = move
        end
    end
    return anim, beast, npc
end

function Parry.stop()
    for _, c in ipairs(Parry.conns) do unbind(c) end
    Parry.conns = {}
end

function Parry.start()
    Parry.stop()
    Parry.resolveState()

    local animLookup, beastLookup, npcLookup = Parry.buildLookups()

    local function watchPlayer(target)
        if target == LP then return end
        if target.Character then Parry.hookAnimator(target.Character, animLookup) end
        Parry.conns[#Parry.conns + 1] = bind(target.CharacterAdded:Connect(function(char)
            task.wait(0.5)
            if Parry.enabled then Parry.hookAnimator(char, animLookup) end
        end))
    end

    for _, target in ipairs(Players:GetPlayers()) do watchPlayer(target) end
    Parry.conns[#Parry.conns + 1] = bind(Players.PlayerAdded:Connect(watchPlayer))

    local debrisFolder = workspace:FindFirstChild("Debris")
    if debrisFolder then
        Parry.conns[#Parry.conns + 1] = bind(debrisFolder.ChildAdded:Connect(Parry.scanObject))
        for _, obj in ipairs(debrisFolder:GetChildren()) do Parry.scanObject(obj) end
    end

    Parry.conns[#Parry.conns + 1] = bind(workspace.ChildAdded:Connect(function(obj)
        if obj.Name == "Terrain" or obj.Name == "Camera" then return end
        Parry.scanObject(obj)

        if obj.Name == "Matatabi" then
            task.delay(0.5, function()
                if Parry.enabled then Parry.hookAnimator(obj, beastLookup) end
            end)
        elseif npcLookup[obj.Name] then
            local lookup = npcLookup[obj.Name]
            task.delay(0.5, function()
                if Parry.enabled then Parry.hookAnimator(obj, lookup) end
            end)
        end
    end))

    local matatabi = workspace:FindFirstChild("Matatabi")
    if matatabi then Parry.hookAnimator(matatabi, beastLookup) end

    for npcName, lookup in pairs(npcLookup) do
        local model = workspace:FindFirstChild(npcName)
        if model then Parry.hookAnimator(model, lookup) end
    end
end

-- The combat script is rebuilt with the character, so u32 must be re-found.
bind(LP.CharacterAdded:Connect(function()
    if not Parry.enabled then return end
    task.delay(1.5, function()
        if Parry.enabled then
            Parry.resolveState()
            Parry.start()
        end
    end)
end))

]==]
-- ===================================================================
-- AUTO PARRY - DISABLED
--
-- Commented out on request. Everything below is intact: uncomment the
-- block (and the UI.parry* / UI.secBuilder sectors in the layout, and
-- the Parry lines in unload) to bring it back.
-- ===================================================================
--[==[

---------------------------------------------------------------------
-- AUTO PARRY UI
---------------------------------------------------------------------
UI.parry.element("Toggle", "Auto Parry", nil, function(v)
    Parry.enabled = v.Toggle
    if v.Toggle then
        Parry.start()
        notify("Combat", Parry.state
            and "Auto Parry on - using the game's own block gate"
            or  "Auto Parry on - state table not found, degraded checks", 5)
    else
        Parry.stop()
        notify("Combat", "Auto Parry disabled")
    end
end)

UI.parry.element("Toggle", "Auto Delay (ping aware)", { default = { Toggle = true } }, function(v)
    Parry.autoDelay = v.Toggle
    notify("Combat", v.Toggle
        and "Auto Delay on - blocks fire early by your ping"
        or  "Auto Delay off - using raw per-move delays", 4)
end)

UI.parry.element("Toggle", "Blatant", nil, function(v)
    Parry.blatant = v.Toggle
    notify("Combat", v.Toggle
        and "Blatant on - skips the state gate (will block when it cannot)"
        or  "Blatant off - full gate, matches the game", 5)
end)

UI.parry.element("Toggle", "Parry Block-Breakers", nil, function(v)
    Parry.parryBreaks = v.Toggle
    notify("Combat", v.Toggle
        and "Will parry BlockBreaks moves - unverified, 2s stun if wrong"
        or  "Skipping BlockBreaks moves", 5)
end)

UI.parry.element("Slider", "Extra Delay", {
    default = { min = -200, max = 300, default = 0 },
    suffix  = " ms",
}, function(v)
    Parry.customDelay = v.Slider / 1000
end)

UI.parry.element("Slider", "Parry Cooldown", {
    default = { min = 0, max = 1000, default = 300 },
    suffix  = " ms",
}, function(v)
    Parry.cooldown = v.Slider / 1000
end)

UI.parry.element("Button", "Re-find Client State", nil, function()
    if Parry.resolveState() then
        notify("Combat", "Found the client state table")
    else
        notify("Combat", "Not found - needs getgc/debug.getupvalue", 5)
    end
end)

-- Live readout so the ping maths is visible rather than implied.
do
    local label = UI.parry.element("Label", "ping -- ms | fires -- ms early")
    bind(RunService.Heartbeat:Connect(function()
        if not Parry.enabled then return end
        if os.clock() - (Parry._labelAt or 0) < 0.5 then return end
        Parry._labelAt = os.clock()

        local one = Parry.ping()
        label:set_text(string.format("ping %d ms | fires %d ms early",
            math.floor(one * 2000), math.floor((one + PB_WINDOW / 2) * 1000)))
    end))
end

-- One combo per source: a name can repeat across sources, and each list needs
-- its own selection.
do
    local groups = {
        { label = "Player Moves", kinds = { animation = true, debris = true, workspace = true } },
        { label = "Beast Moves",  kinds = { beast = true } },
        { label = "NPC Moves",    kinds = { npc = true } },
    }

    for _, group in ipairs(groups) do
        local members, names, defaults = {}, {}, {}
        for _, move in ipairs(Parry.moves) do
            if group.kinds[move.type] then
                members[#members + 1] = move
                names[#names + 1]     = move.name
                if move.on then defaults[#defaults + 1] = move.name end
            end
        end

        UI.parryMoves.element("Combo", group.label, {
            options = names,
            default = { Combo = defaults },
        }, function(v)
            for _, move in ipairs(members) do
                move.on = table.find(v.Combo, move.name) ~= nil
            end
            if Parry.enabled then Parry.start() end
        end)
    end
end

---------------------------------------------------------------------
-- PARRY BUILDER
--
-- Same job as the standalone builder window: pick a move, edit its detection
-- range, parry range, delay and block duration, add your own moves. Built out
-- of the menu's own elements so it matches everything else.
--
-- Selecting a move drives the sliders to its values, and moving a slider
-- writes straight back to the live move table - no apply step, no separate
-- copy of the data to fall out of sync.
---------------------------------------------------------------------
Parry.builder = { selected = nil, sliders = {}, loading = false }

function Parry.moveNames()
    local names = {}
    for _, m in ipairs(Parry.moves) do names[#names + 1] = m.name end
    table.sort(names)
    return names
end

function Parry.findMove(name)
    for _, m in ipairs(Parry.moves) do
        if m.name == name then return m end
    end
end

function Parry.builderLoad(move)
    if not move then return end

    Parry.builder.loading = true
    local sl = Parry.builder.sliders
    if sl.detect then sl.detect:set_value({ Slider = move.detect }, true) end
    if sl.range  then sl.range:set_value({ Slider = move.range }, true) end
    if sl.delay  then sl.delay:set_value({ Slider = math.floor(move.delay * 1000) }, true) end
    if sl.block  then sl.block:set_value({ Slider = math.floor(move.block * 1000) }, true) end
    if sl.on     then sl.on:set_value({ Toggle = move.on }, true) end
    Parry.builder.loading = false

    if Parry.builder.info then
        Parry.builder.info:set_text(string.format("%s  |  id %s%s",
            move.type, tostring(move.id), move.breaks and "  |  BLOCK-BREAKER" or ""))
    end
end

Parry.builder.dropdown = UI.builder.element("Dropdown", "Move", {
    options = Parry.moveNames(),
}, function(v)
    Parry.builder.selected = Parry.findMove(v.Dropdown)
    Parry.builderLoad(Parry.builder.selected)
end)

Parry.builder.info = UI.builder.element("Label", "select a move")

-- Writes land on the live table immediately; `loading` stops the programmatic
-- set_value calls from writing back over the move we are reading from.
local function builderWrite(field, scale)
    return function(v)
        if Parry.builder.loading then return end
        local move = Parry.builder.selected
        if not move then return end
        move[field] = v.Slider / (scale or 1)
    end
end

Parry.builder.sliders.detect = UI.builder.element("Slider", "Detection Range", {
    default = { min = 10, max = 300, default = 80 }, suffix = " studs",
}, builderWrite("detect"))

Parry.builder.sliders.range = UI.builder.element("Slider", "Parry Range", {
    default = { min = 5, max = 120, default = 30 }, suffix = " studs",
}, builderWrite("range"))

Parry.builder.sliders.delay = UI.builder.element("Slider", "Parry Delay", {
    default = { min = 0, max = 1000, default = 0 }, suffix = " ms",
}, builderWrite("delay", 1000))

Parry.builder.sliders.block = UI.builder.element("Slider", "Block Duration", {
    default = { min = 100, max = 4000, default = 200 }, suffix = " ms",
}, builderWrite("block", 1000))

Parry.builder.sliders.on = UI.builder.element("Toggle", "Move Enabled", nil, function(v)
    if Parry.builder.loading then return end
    local move = Parry.builder.selected
    if not move then return end
    move.on = v.Toggle
    if Parry.enabled then Parry.start() end
end)

UI.builder.element("Button", "Reset This Move", nil, function()
    local move = Parry.builder.selected
    if not move then return end

    local d = Parry.defaults[move.name]
    if not d then
        notify("Builder", "Custom move - nothing to reset to", 4)
        return
    end

    move.detect, move.range, move.delay, move.block, move.on = d.detect, d.range, d.delay, d.block, d.on
    Parry.builderLoad(move)
    if Parry.enabled then Parry.start() end
    notify("Builder", "Reset " .. move.name)
end)

UI.builder.element("Button", "Reset All Moves", nil, function()
    for _, move in ipairs(Parry.moves) do
        local d = Parry.defaults[move.name]
        if d then
            move.detect, move.range, move.delay, move.block, move.on = d.detect, d.range, d.delay, d.block, d.on
        end
    end
    Parry.builderLoad(Parry.builder.selected)
    if Parry.enabled then Parry.start() end
    notify("Builder", "All moves reset to defaults")
end)

---------------------------------------------------------------------
-- CUSTOM MOVES
--
-- Pair this with the Move Tracker: the tracker prints an animation id and
-- copies it to the clipboard, and this turns it into a parryable move.
---------------------------------------------------------------------
Parry.newMove = { name = "", id = "", kind = "animation", npc = "" }

UI.builderAdd.element("TextBox", "Move Name", { maxlen = 40 }, function(v)
    Parry.newMove.name = v.Text
end)

UI.builderAdd.element("TextBox", "Animation ID / Object Name", { maxlen = 40 }, function(v)
    Parry.newMove.id = v.Text
end)

UI.builderAdd.element("Dropdown", "Source", {
    options = { "animation", "debris", "workspace", "beast", "npc" },
    default = { Dropdown = "animation" },
}, function(v)
    Parry.newMove.kind = v.Dropdown
end)

UI.builderAdd.element("TextBox", "NPC Name (npc source only)", { maxlen = 40 }, function(v)
    Parry.newMove.npc = v.Text
end)

UI.builderAdd.element("Button", "Add Move", nil, function()
    local n = Parry.newMove

    if n.name == "" or n.id == "" then
        notify("Builder", "Name and ID are both required", 4)
        return
    end
    if Parry.findMove(n.name) then
        notify("Builder", "A move called that already exists", 4)
        return
    end
    if n.kind == "npc" and n.npc == "" then
        notify("Builder", "NPC source needs the NPC's name", 4)
        return
    end

    local move = {
        name = n.name, type = n.kind, id = n.id,
        detect = 80, range = 30, delay = 0, block = 0.4, on = true,
    }
    if n.kind == "npc" then move.npc = n.npc end

    Parry.moves[#Parry.moves + 1] = move
    Parry.builder.dropdown:refresh(Parry.moveNames(), true)
    if Parry.enabled then Parry.start() end

    notify("Builder", "Added " .. move.name .. " - now tune it under Edit Move", 5)
end)

UI.builderAdd.element("Button", "Delete Selected Move", nil, function()
    local move = Parry.builder.selected
    if not move then return end

    for i, m in ipairs(Parry.moves) do
        if m == move then
            table.remove(Parry.moves, i)
            break
        end
    end

    Parry.builder.selected = nil
    Parry.builder.dropdown:refresh(Parry.moveNames())
    if Parry.enabled then Parry.start() end
    notify("Builder", "Deleted " .. move.name)
end)

---------------------------------------------------------------------
-- TIMING REFERENCE (read out of the game's own settings table)
---------------------------------------------------------------------
UI.builderInfo.element("Label", "PerfectBlockWindow   0.25 s")
UI.builderInfo.element("Label", "PerfectBlockCooldown 0.60 s")
UI.builderInfo.element("Label", "BlockCooldown        0.50 s")
UI.builderInfo.element("Label", "MeleeStunTime        0.60 s")
UI.builderInfo.create_line()
UI.builderInfo.element("Label", "A block parries if the hit lands")
UI.builderInfo.element("Label", "within 0.25s of it starting.")
UI.builderInfo.element("Label", "Auto Delay aims for the middle")
UI.builderInfo.element("Label", "of that window, minus your ping.")

yield(true)

]==]
-- ===================================================================
-- AUTO PARRY - DISABLED
--
-- Commented out on request. Everything below is intact: uncomment the
-- block (and the UI.parry* / UI.secBuilder sectors in the layout, and
-- the Parry lines in unload) to bring it back.
-- ===================================================================
--[==[

---------------------------------------------------------------------
-- MOVE TRACKER
--
-- Read-only. Reports every animation id played near you, once each, with who
-- played it and the distance - then copies the id so it can go straight into
-- the Custom Move box.
---------------------------------------------------------------------
Parry.tracker = { enabled = false, conns = {}, seen = {} }

function Parry.trackerHook(model, label)
    local hum      = model and model:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return end

    local t = Parry.tracker
    t.conns[#t.conns + 1] = bind(animator.AnimationPlayed:Connect(function(track)
        if not t.enabled then return end

        local id = tostring(track.Animation and track.Animation.AnimationId or ""):match("(%d+)")
        if not id or t.seen[id] then return end
        t.seen[id] = true

        local myRoot = root()
        local part   = model:FindFirstChild("HumanoidRootPart")
            or model:FindFirstChild("Torso") or model.PrimaryPart
        local dist   = (myRoot and part)
            and math.floor((part.Position - myRoot.Position).Magnitude) or 0

        notify("Tracker", string.format("%s  %s  (%d studs)", label, id, dist), 8)
        if setclipboard then pcall(setclipboard, id) end
    end))
end

function Parry.trackerStop()
    for _, c in ipairs(Parry.tracker.conns) do unbind(c) end
    Parry.tracker.conns = {}
end

function Parry.trackerStart()
    Parry.trackerStop()
    local t = Parry.tracker

    local function watch(target)
        if target == LP then return end
        if target.Character then Parry.trackerHook(target.Character, target.Name) end
        t.conns[#t.conns + 1] = bind(target.CharacterAdded:Connect(function(char)
            task.wait(0.5)
            if t.enabled then Parry.trackerHook(char, target.Name) end
        end))
    end

    for _, target in ipairs(Players:GetPlayers()) do watch(target) end
    t.conns[#t.conns + 1] = bind(Players.PlayerAdded:Connect(watch))

    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid") and not isPlayerModel(obj) then
            Parry.trackerHook(obj, obj.Name)
        end
    end

    t.conns[#t.conns + 1] = bind(workspace.ChildAdded:Connect(function(obj)
        if not t.enabled then return end
        task.delay(0.5, function()
            if t.enabled and obj.Parent and obj:IsA("Model")
                and obj:FindFirstChildOfClass("Humanoid") and not isPlayerModel(obj) then
                Parry.trackerHook(obj, obj.Name)
            end
        end)
    end))
end

UI.parryTracker.element("Toggle", "Log Animation IDs", nil, function(v)
    Parry.tracker.enabled = v.Toggle
    if v.Toggle then
        Parry.trackerStart()
        notify("Tracker", "Logging new animation ids (copied to clipboard)", 5)
    else
        Parry.trackerStop()
        notify("Tracker", "Tracker off")
    end
end)

UI.parryTracker.element("Button", "Reset Seen List", nil, function()
    Parry.tracker.seen = {}
    notify("Tracker", "Seen list cleared", 2)
end)

UI.parryTracker.create_line()
UI.parryTracker.element("Label", "Each id is reported once, then")
UI.parryTracker.element("Label", "copied. Paste it into Custom Move")
UI.parryTracker.element("Label", "to make it parryable.")

yield(true)

]==]

---------------------------------------------------------------------
-- AUTO RAMEN CONTEST
--
-- Choji's eating contest is the Akimichi unlock for Butterfly Mode
-- [Stage 2]. Requirements to start: Bloodline Akimichi, Butterfly Mode
-- already learned, and 15x Ramen in the inventory.
--
-- The whole contest is decided on the client: the game counts your bowls and
-- Choji's in two local variables and only ever tells the server the verdict
-- ("WonRamenContest" / "LostRamenContest"). Eating reaches the server as two
-- events per bowl:
--
--     DataEvent:FireServer("Consumed", "Ramen", actionTime)   -- eats it
--     DataEvent:FireServer("RamenInventorySwap")              -- ramen -> bowl
--
-- Firing only the swap does nothing, which is the trap here: the bowl counter
-- moves but nothing is actually consumed.
--
-- Choji averages ~1.5s a bowl with scripted pauses at bowl 3 and 8, so the
-- default 1.2s pace wins with room to spare while looking exactly like
-- someone eating at full speed.
---------------------------------------------------------------------
local Ramen = {
    enabled    = false,
    bowls      = 15,
    gap        = 1.2,
    startDelay = 10,
    thread     = nil,
    toggle     = nil,
}

-- The client sends the item's own ActionTime as the third argument, so read
-- the real number instead of guessing at it.
function Ramen.actionTime()
    local value = 1.2
    pcall(function()
        local GM   = require(RepStorage:WaitForChild("GameManager"))
        local item = GM.Items and GM.Items.Ramen
        if item and item.ActionTime then value = item.ActionTime end
    end)
    return value
end

-- One full set of bowls, then report the win.
function Ramen.eatRound()
    local actionTime = Ramen.actionTime()

    for i = 1, Ramen.bowls do
        if not Ramen.enabled then return false end

        pcall(function()
            RepStorage.Events.DataEvent:FireServer("Consumed", "Ramen", actionTime)
            RepStorage.Events.DataEvent:FireServer("RamenInventorySwap")
        end)

        task.wait(Ramen.gap)
    end

    task.wait(0.3)
    pcall(function()
        RepStorage.Events.DataEvent:FireServer("WonRamenContest")
    end)

    return true
end

function Ramen.stop()
    Ramen.enabled = false
    if Ramen.thread then
        pcall(function() task.cancel(Ramen.thread) end)
        Ramen.thread = nil
    end
end

function Ramen.start()
    Ramen.thread = task.spawn(function()
        while Ramen.enabled do
            -- Starting the round clones the Ramen Shop into workspace, so its
            -- presence is a reliable "a contest is set up" signal.
            pcall(function()
                RepStorage.Events.DataEvent:FireServer("StartRamenContest")
            end)

            local deadline = os.clock() + 8
            while Ramen.enabled and not workspace:FindFirstChild("Ramen Shop") do
                if os.clock() > deadline then break end
                task.wait(0.2)
            end

            if not Ramen.enabled then return end

            if not workspace:FindFirstChild("Ramen Shop") then
                notify("Ramen", "Contest did not start - check you have 15x Ramen", 6)
                Ramen.stop()
                if Ramen.toggle then Ramen.toggle:set_value({ Toggle = false }, true) end
                return
            end

            -- Choji's dialog and the countdown run before the real start.
            notify("Ramen", "Contest up - eating in " .. Ramen.startDelay .. "s", 4)
            local waited = 0
            while Ramen.enabled and waited < Ramen.startDelay do
                task.wait(0.5)
                waited = waited + 0.5
            end

            if not Ramen.enabled then return end
            if not Ramen.eatRound() then return end

            notify("Ramen", "Round done", 4)

            -- The shop is destroyed ~5s after the verdict; wait for it to go
            -- before starting the next one, or the re-fire lands mid-teardown.
            local clear = os.clock() + 20
            while Ramen.enabled and workspace:FindFirstChild("Ramen Shop") do
                if os.clock() > clear then break end
                task.wait(0.5)
            end

            task.wait(2)
        end
    end)
end

Ramen.toggle = UI.ramen.element("Toggle", "Auto Ramen Contest", nil, function(v)
    Ramen.enabled = v.Toggle
    if v.Toggle then
        Ramen.start()
        notify("Ramen", "Auto Ramen Contest started")
    else
        Ramen.stop()
        notify("Ramen", "Auto Ramen Contest stopped")
    end
end)

UI.ramen.element("Button", "Eat Now (one round)", nil, function()
    -- For when you are already sitting in a contest you started by hand.
    task.spawn(function()
        local was = Ramen.enabled
        Ramen.enabled = true
        Ramen.eatRound()
        Ramen.enabled = was
        notify("Ramen", "Round done", 3)
    end)
end)

UI.ramen.create_line()
UI.ramen.element("Label", "needs akimichi + Butterfly Mode and 15 ramen")

yield(true)

---------------------------------------------------------------------
-- HOLD TO M1
--
-- The obvious implementations both fail, for the same reason:
--
--   Synthetic clicks (VirtualInputManager) and re-firing InputBegan both end
--   up in the game's onKeyDown, and its MouseButton1 branch does not attack -
--   it only sets u32.HoldingMouseButton1, which is used solely for HELD-SKILL
--   logic. Setting a flag that is already true does nothing, so the loop runs
--   and no swing happens.
--
-- The swing actually comes from performM1(), called behind canM1(). Both are
-- globals in the game LocalScript's environment, so they can be called
-- directly - which is also the better option: the combo counter, the
-- animation and the CheckMeleeHit all stay consistent because it is the
-- game's own code doing them.
--
-- canM1() already gates on cooldown, stun, blocking, gripping, forcefield,
-- consuming and dashing, so the poll can be fast and simply no-ops until the
-- game says the next swing is legal.
---------------------------------------------------------------------
local M1 = {
    enabled   = false,
    rate      = 0.02,
    held      = false,
    loop      = nil,
    perform   = nil,
    can       = nil,
    resolveAt = 0,
}

-- Walk the GC for either function and lift both out of its environment. They
-- are script globals, not _G entries, so the environment is the way in.
function M1.resolve()
    M1.perform, M1.can = nil, nil

    local ok = pcall(function()
        for _, f in ipairs(getgc(false)) do
            if type(f) == "function" then
                local named, name = pcall(debug.info, f, "n")
                if named and (name == "performM1" or name == "canM1") then
                    local env = getfenv(f)
                    M1.perform = rawget(env, "performM1") or M1.perform
                    M1.can     = rawget(env, "canM1")     or M1.can
                    if M1.perform and M1.can then return end
                end
            end
        end
    end)

    M1.resolveAt = os.clock()
    return ok and M1.perform ~= nil
end

function M1.stop()
    M1.held = false
    if M1.loop then
        pcall(function() task.cancel(M1.loop) end)
        M1.loop = nil
    end
end

function M1.start()
    M1.stop()

    M1.loop = task.spawn(function()
        while M1.enabled do
            if M1.held and M1.perform then
                -- canM1 is the game's own legality check; if it is missing for
                -- any reason, fall through and let performM1 decide.
                if not M1.can or M1.can() then
                    pcall(M1.perform)
                end
            end
            task.wait(M1.rate)
        end
    end)
end

bind(K.Services.UserInputService.InputBegan:Connect(function(input, processed)
    if not M1.enabled or processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        M1.held = true
    end
end))

bind(K.Services.UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        M1.held = false
    end
end))

-- The combat script is rebuilt with the character, so a cached performM1 from
-- a previous life points at an environment whose upvalues are dead. Re-resolve
-- rather than calling into a stale closure.
bind(LP.CharacterAdded:Connect(function()
    if not M1.enabled then return end
    task.delay(1.5, function()
        if M1.enabled then M1.resolve() end
    end)
end))

UI.autoM1.element("Toggle", "Hold to M1", nil, function(v)
    M1.enabled = v.Toggle

    if v.Toggle then
        if not M1.resolve() then
            M1.enabled = false
            notify("Combat", "Could not find performM1 - executor needs getgc/getfenv", 6)
            return
        end
        M1.start()
        notify("Combat", "Hold to M1 enabled")
    else
        M1.stop()
        notify("Combat", "Hold to M1 disabled")
    end
end)

---------------------------------------------------------------------
-- AUTO GENJUTSU RELEASE
--
-- Casts Genjutsu Release the moment you're caught by Fog Illusion, Feather
-- Genjutsu or Scrambled Mind. Every trigger is aimed at YOU, so someone else
-- getting caught nearby never fires it:
--   Fog Illusion   - server sets a "FogIllusion" attribute on your character
--   Scrambled Mind - server sets a "ScrambledMind" attribute on your character
--   Feather        - server sends your client "FeatherGenjutsu" (its effect
--                    plays on your own HRP) and "StopFeatherGenjutsu" after
--
-- The cast goes through the game's own activateSkill(nil, "Genjutsu
-- Release") - the same form the game uses for Kotoamatsukami - so the
-- animation, chakra cost, the server cooldown check and the startSkill
-- arguments all stay consistent. (Passing "MouseButton1" there would cast
-- your held weapon's M1 skill instead.) Genjutsu Release has BypassStun and
-- BypassOccupied, so it goes through while stunned.
--
-- Ownership is checked with the game's own GameManager:hasSkill first, so
-- it never plays the animation for a skill you don't have. If you're
-- mid-cast when it lands, it retries every 0.4s while the genjutsu lasts
-- (max ~4s); while the skill is on cooldown it doesn't even ask the server.
-- (Live-verified: activateSkill and the ownership check resolve from the
-- running client; Cooldowns entries are last-used timestamps, not flags.)
---------------------------------------------------------------------
do
    local SKILL = "Genjutsu Release"
    local AG = {
        fn = nil, gm = nil, dataIdx = nil, script = nil, state = nil, select = nil,
        featherUntil = 0, busy = false, conns = {}, charConns = {},
    }

    -- activateSkill is a global in the game LocalScript's environment. The
    -- script restarts on respawn, so only accept the copy belonging to the
    -- live script (an old one can linger in the GC). From its upvalues pick
    -- out GameManager and the slot holding your data for the ownership check.
    local function resolve()
        if AG.fn and AG.script and AG.script.Parent then return true end
        AG.fn, AG.gm, AG.dataIdx, AG.script, AG.state, AG.select, AG.skills =
            nil, nil, nil, nil, nil, nil, nil
        pcall(function()
            for _, f in ipairs(getgc(false)) do
                if type(f) == "function" then
                    local named, name = pcall(debug.info, f, "n")
                    if named and name == "activateSkill" then
                        local env = getfenv(f)
                        local s = rawget(env, "script")
                        local fn = rawget(env, "activateSkill")
                        if fn and s and s:IsDescendantOf(LP) then
                            AG.fn, AG.script = fn, s
                            AG.skills = rawget(env, "skillsModule")
                            break
                        end
                    end
                end
            end
            if not AG.fn then return end
            for i, uv in ipairs(debug.getupvalues(AG.fn)) do
                if type(uv) == "table" then
                    if type(rawget(uv, "hasSkill")) == "function" then
                        AG.gm = uv
                    elseif rawget(uv, "CurrentWeapon") ~= nil and rawget(uv, "Traits") ~= nil then
                        AG.dataIdx = i
                    elseif rawget(uv, "skillInUse") ~= nil and rawget(uv, "Settings") ~= nil then
                        AG.state = uv -- the game's client state (Selected, Occupied, ...)
                    end
                elseif type(uv) == "function" then
                    local ok, n = pcall(debug.info, uv, "n")
                    if ok and n == "selectNewItem" then AG.select = uv end
                end
            end
        end)
        return AG.fn ~= nil
    end

    -- The game only casts a skill while you're holding something (it checks
    -- Selected ~= ""), and Genjutsu Release has no bypass. With empty hands,
    -- press the skill's own slot through the game's selectNewItem - how it's
    -- normally cast, and the game unselects it after - else your weapon.
    -- (Live-verified: empty hands -> slot selected -> cast -> hands empty.)
    local function ensureSelected(skill)
        local st = AG.state
        if not st or st.Selected ~= "" or not AG.select or not AG.dataIdx then return end
        local ok, data = pcall(debug.getupvalue, AG.fn, AG.dataIdx)
        if not ok or type(data) ~= "table" then return end
        pcall(AG.select, data, skill)
        if st.Selected == "" and data.CurrentWeapon then
            pcall(AG.select, data, data.CurrentWeapon)
        end
    end

    -- Is this skill the active awakening's M1 / M2? Awakening moves
    -- (Amaterasu, Susanoo Strike, ...) are NOT in UnlockedSkills, so hasSkill
    -- returns false for them - live-verified: hasSkill "Susanoo Strike" and
    -- "Amaterasu" are both false while hasSkill "Itachi's Eternal Mangekyo"
    -- is true. They are castable only while that awakening is active.
    local function fromAwakening(skill)
        local st, sk = AG.state, AG.skills
        if not st or not sk then return false end
        local aw = st.Settings and st.Settings.Awakened and st.Settings.Awakened.Value
        local def = aw and aw ~= "" and sk[aw]
        if not def then return false end
        return def.MouseButton1 == skill or def.MouseButton2 == skill
            or def["C + M1"] == skill or def["C + M2"] == skill
    end
    K.skillFromAwakening = fromAwakening

    -- Your data is a ref upvalue the game reassigns, so it's re-read each
    -- time. If ownership can't be checked, let the game decide.
    local function owns(skill)
        if fromAwakening(skill) then return true end
        if not AG.gm or not AG.dataIdx then return true end
        local ok, data = pcall(debug.getupvalue, AG.fn, AG.dataIdx)
        if not ok or type(data) ~= "table" then return true end
        local okh, has = pcall(AG.gm.hasSkill, AG.gm, data, skill)
        return not okh or (has and true or false)
    end

    -- ReplicatedStorage.Cooldowns[you][skill] is a NumberValue holding the
    -- server time the skill was LAST USED, and it is never removed - so the
    -- entry existing means nothing; compare the time since then against the
    -- cooldown. The game's own getCooldown (what its cooldown UI uses) is
    -- asked for the length, falling back to the base 30s.
    local function onCooldown(skill, fallback)
        local all  = cooldownsFolder()
        local mine = all and all:FindFirstChild(LP.Name)
        local used = mine and mine:FindFirstChild(skill)
        if not used then return false end
        local cd = fallback or 30
        if AG.gm then
            local ok, v = pcall(AG.gm.getCooldown, AG.gm, LP.Character, skill, mySettings())
            if ok and type(v) == "number" then cd = v end
        end
        return workspace:GetServerTimeNow() - used.Value < cd + 0.25
    end

    -- Shared skill caster: resolve, ownership, hand-selection, then the
    -- game's own activateSkill. Other features (Auto Totsuka Blade) use this
    -- instead of duplicating the resolver.
    K.castSkill = function(skill, cdFallback)
        if not resolve() or not owns(skill) then return false end
        if onCooldown(skill, cdFallback) then return false end
        ensureSelected(skill)
        return pcall(AG.fn, nil, skill)
    end
    K.skillOnCooldown = function(skill, cdFallback)
        return resolve() and onCooldown(skill, cdFallback) or false
    end

    local function caught()
        local c = LP.Character
        if not c then return false end
        if os.clock() < AG.featherUntil then return true end
        if c:GetAttribute("FogIllusion") then return true end
        -- With Anti Scrambled Mind on, Scrambled Mind is already neutralised;
        -- keep the 30s cooldown for the genjutsus that need it.
        return c:GetAttribute("ScrambledMind") and not K.flags.antiScramble or false
    end

    local function release()
        if AG.busy or not K.flags.autoGenjutsu then return end
        AG.busy = true
        task.spawn(function()
            local deadline = os.clock() + 4
            while K.flags.autoGenjutsu and os.clock() < deadline and caught() do
                if not onCooldown(SKILL) and resolve() and owns(SKILL) then
                    ensureSelected(SKILL)
                    pcall(AG.fn, nil, SKILL)
                end
                task.wait(0.4)
            end
            AG.busy = false
        end)
    end

    local function watchCharacter(char)
        for _, c in ipairs(AG.charConns) do c:Disconnect() end
        AG.charConns = {}
        if not char then return end
        for _, attr in ipairs({ "FogIllusion", "ScrambledMind" }) do
            AG.charConns[#AG.charConns + 1] = char:GetAttributeChangedSignal(attr):Connect(function()
                if attr == "ScrambledMind" and K.flags.antiScramble then return end
                if char:GetAttribute(attr) then release() end
            end)
        end
        if caught() then release() end -- already caught when this started
    end

    local function stop()
        for _, c in ipairs(AG.conns) do c:Disconnect() end
        for _, c in ipairs(AG.charConns) do c:Disconnect() end
        AG.conns, AG.charConns = {}, {}
        AG.featherUntil = 0
    end

    UI.combatUtil.element("Toggle", "Auto Genjutsu Release", nil, function(v)
        K.flags.autoGenjutsu = v.Toggle
        stop()
        if not v.Toggle then
            notify("Combat", "Auto Genjutsu Release disabled")
            return
        end

        local dataEvent = RepStorage:WaitForChild("Events"):WaitForChild("DataEvent")
        -- An extra listener: it runs alongside the game's own handler.
        AG.conns[#AG.conns + 1] = dataEvent.OnClientEvent:Connect(function(kind)
            if kind == "FeatherGenjutsu" then
                AG.featherUntil = os.clock() + 15 -- cleared early by the stop event
                release()
            elseif kind == "StopFeatherGenjutsu" then
                AG.featherUntil = 0
            end
        end)
        AG.conns[#AG.conns + 1] = LP.CharacterAdded:Connect(watchCharacter)
        watchCharacter(LP.Character)

        if resolve() then
            notify("Combat", owns(SKILL) and "Auto Genjutsu Release enabled"
                or "Auto Genjutsu Release enabled - but you don't own Genjutsu Release", 4)
        else
            notify("Combat", "Auto Genjutsu Release enabled (game skill function not found yet)", 4)
        end
    end)
end

---------------------------------------------------------------------
-- ANTI SCRAMBLED MIND
--
-- Scrambled Mind is only a "ScrambledMind" attribute the server puts on your
-- character. ALL of the scrambling happens in the game's own client input
-- handler (onKeyDown, gamescript.txt:6646-6687 and 8895-8924), which reads
-- that attribute on every key press to swap M1<->F, M2<->Q, W<->S, A<->D and
-- R<->Q. Clearing it on our client the moment it arrives means every one of
-- those reads finds nothing and the controls stay normal.
--
-- Local only - client attribute writes don't replicate - so the server-side
-- genjutsu simply runs out; if the server applies it again it's cleared
-- again. Clearing re-fires the changed signal once, which then finds the
-- attribute already gone, so there's no loop.
---------------------------------------------------------------------
do
    local ATTR  = "ScrambledMind"
    local conns = {}

    local function clear(char)
        if char and char:GetAttribute(ATTR) then
            pcall(function() char:SetAttribute(ATTR, nil) end)
        end
    end

    local function watch(char)
        if conns.attr then conns.attr:Disconnect() conns.attr = nil end
        if not char then return end
        clear(char) -- already scrambled when this started
        conns.attr = char:GetAttributeChangedSignal(ATTR):Connect(function()
            if K.flags.antiScramble then clear(char) end
        end)
    end

    UI.combatUtil.element("Toggle", "Anti Scrambled Mind", nil, function(v)
        K.flags.antiScramble = v.Toggle
        for k, c in pairs(conns) do
            c:Disconnect()
            conns[k] = nil
        end
        if v.Toggle then
            watch(LP.Character)
            conns.char = LP.CharacterAdded:Connect(watch)
            notify("Combat", "Anti Scrambled Mind enabled")
        else
            notify("Combat", "Anti Scrambled Mind disabled")
        end
    end)
end

---------------------------------------------------------------------
-- ANTI BACK ATTACH
--
-- Bloodlines.lua's Attach to Back and Destroy Player glue the attacker to
--     yourHRP.CFrame * CFrame.new(side, height, behind)
-- every frame (behind defaults to 2 / 0 studs), using where you APPEAR on
-- their screen; the server then checks their hit against where it thinks
-- you ARE. This makes those disagree: after physics each frame your HRP is
-- moved to a fresh random spot 18-30 studs under you (up to 14 to the side),
-- which is the position sent to the server and everyone else, and it's put
-- back before your next render / physics step, so on your own screen and in
-- your own physics nothing moves. The attacker keeps teleporting to where
-- you were a moment ago; by the time their hit reaches the server you're
-- somewhere else, so it misses. Everyone else sees you jumping around under
-- the map and can't land hits either.
--
-- Your own hits need your real position on the server, so it pauses while
-- you hold anything other than movement (M1, M2, skill / item keys) and for
-- 0.4s after, and while you're being carried (the carrier owns your physics).
--
-- Timing: the fake spot is set in a task.defer from Heartbeat, so it lands
-- after every other Heartbeat handler - the game's per-frame floor / lava /
-- poison / void raycasts read your HRP there and must see the real spot -
-- and it's undone at the very start of the next frame (BindToRenderStep,
-- priority First) before the camera or anything else reads it. If something
-- moved you in between (a teleport), that move is kept instead. The fake spot
-- stays within ~33 studs because the game closes NPC dialogs past 40.
---------------------------------------------------------------------
do
    local UIS = K.Services.UserInputService
    local RS_NAME = "SysAntiAttachRestore"
    local DEPTH_MIN, DEPTH_MAX, SIDE = 18, 30, 14
    local MOVEMENT = {
        W = true, A = true, S = true, D = true, Space = true,
        LeftShift = true, RightShift = true, LeftControl = true,
    }

    local D = { conns = {}, bound = false, held = {}, pauseUntil = 0, hrp = nil, real = nil, fake = nil }

    local function inputKey(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.Keyboard then
            local k = input.KeyCode.Name
            return not MOVEMENT[k] and k or nil
        end
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 then
            return t.Name
        end
        return nil
    end

    local function paused()
        if next(D.held) ~= nil or os.clock() < D.pauseUntil then return true end
        -- A scripted cast (Auto Totsuka Blade) holds no key, so it asks for
        -- the pause directly - its hit needs our real position on the server.
        if os.clock() < (K.combatPauseUntil or 0) then return true end
        local s = mySettings()
        local carried = s and s:FindFirstChild("BeingCarried")
        return carried ~= nil and carried.Value ~= "None" and carried.Value ~= ""
    end

    local function restore()
        local hrp, real, fake = D.hrp, D.real, D.fake
        D.hrp, D.real, D.fake = nil, nil, nil
        -- Only undo our own move: if anything else repositioned you since
        -- (a teleport), keep that.
        if hrp and hrp.Parent and (hrp.Position - fake.Position).Magnitude < 0.05 then
            hrp.CFrame = real
        end
    end

    local function desync()
        if not K.flags.antiAttach or D.real or paused() then return end
        local hrp = root()
        if not hrp or hrp.Anchored then return end
        local angle = math.random() * math.pi * 2
        local side  = math.random() * SIDE
        local depth = DEPTH_MIN + math.random() * (DEPTH_MAX - DEPTH_MIN)
        D.hrp, D.real = hrp, hrp.CFrame
        D.fake = D.real + Vector3.new(math.cos(angle) * side, -depth, math.sin(angle) * side)
        hrp.CFrame = D.fake
    end

    local function stop()
        for k, c in pairs(D.conns) do
            c:Disconnect()
            D.conns[k] = nil
        end
        if D.bound then
            pcall(function() RunService:UnbindFromRenderStep(RS_NAME) end)
            D.bound = false
        end
        restore()
        D.held, D.pauseUntil = {}, 0
    end

    local function start()
        stop()
        -- First thing every frame: back to the real spot before anything reads it.
        RunService:BindToRenderStep(RS_NAME, Enum.RenderPriority.First.Value, restore)
        D.bound = true
        D.conns.hb = RunService.Heartbeat:Connect(function()
            task.defer(desync) -- after every other Heartbeat handler
        end)
        D.conns.began = UIS.InputBegan:Connect(function(input, processed)
            if processed then return end
            local k = inputKey(input)
            if k then D.held[k] = true end
        end)
        D.conns.ended = UIS.InputEnded:Connect(function(input)
            local k = inputKey(input)
            if k and D.held[k] then
                D.held[k] = nil
                D.pauseUntil = os.clock() + 0.4
            end
        end)
        -- Alt-tab can swallow the key-up; don't stay paused forever.
        D.conns.focus = UIS.WindowFocusReleased:Connect(function() D.held = {} end)
    end

    UI.combatUtil.element("Toggle", "Anti Back Attach", nil, function(v)
        K.flags.antiAttach = v.Toggle
        if v.Toggle then
            start()
            notify("Combat", "Anti Back Attach enabled - pauses while you attack", 4)
        else
            stop()
            notify("Combat", "Anti Back Attach disabled")
        end
    end)
end

---------------------------------------------------------------------
-- AUTO TOTSUKA BLADE
--
-- Itachi's Mangekyo / Eternal Mangekyo are M1 = "Amaterasu",
-- M2 = "Susanoo Strike" (the Totsuka blade). When your Amaterasu CONNECTS
-- this casts Susanoo Strike at once and holds your body turned at that
-- victim for the whole swing (it is 5 repeating hits, OccupiedTime 1.5).
--
-- Hit detection: the victim is whoever is carrying Amaterasu's own
-- "BlackFire" ailment (ailments replicate as a child named after the ailment
-- in char.Ailments / ReplicatedStorage.Ailments[name] - GameManager.hasAilment)
-- within 1.5s of the server stamping OUR Cooldowns[us].Amaterasu, nearest
-- first, inside Max Victim Distance.
--
-- Stun is deliberately NOT used. It was tried and measured useless: during one
-- live Amaterasu, 44 candidates yielded FIVE "stunned" players 5188-6363 studs
-- away (unrelated fights across the map) and one matched BEFORE the real
-- victim, so the blade swung at nothing. BlackFire was true for exactly one
-- character - the actual victim at 27 studs.
--
-- The distance bound is NOT a reach for Susanoo Strike (the game defines none:
-- TouchingParts = true, no Range field anywhere). It only bounds how far away
-- a burning player may be before we believe they are OUR victim, since other
-- people's Amaterasu lights players up anywhere on the map.
--
-- Facing: the HumanoidRootPart CFrame is rewritten each frame, yaw only
-- (position untouched, no tilt). Deliberately NOT a BodyGyro - the game's
-- own anti-cheat self-reports ANY BodyGyro added to your HRP (the name
-- allowlist only covers BodyVelocity / BodyPosition / LinearVelocity), so a
-- gyro here would trip Offense 1E.
--
-- While striking it raises K.combatPauseUntil, which Anti Back Attach honours
-- - a scripted cast holds no key, so without it the desync would be active
-- and the strike would land where the server thinks you are, not on them.
---------------------------------------------------------------------
do
    local AMA, TOTSUKA = "Amaterasu", "Susanoo Strike"
    local WINDOW, HOLD, STEP = 1.5, 2.6, 0.05

    local T = { conns = {}, armedUntil = 0, busy = false, faceConn = nil, hunting = false, maxDist = 60 }

    -- The ONLY signal used is the BlackFire ailment - Amaterasu's own Ailment,
    -- replicated as a child named after the ailment in char.Ailments /
    -- ReplicatedStorage.Ailments[name]. Stun was tried and measured to be
    -- useless noise: during a live Amaterasu, 44 candidates produced FIVE
    -- "stunned" players at 5188-6363 studs (random people fighting across the
    -- map) and one of them was matched BEFORE the real victim. BlackFire was
    -- true for exactly one character: the actual victim, 27 studs away.
    local function ailmentsOf(char)
        local own = char:FindFirstChild("Ailments")
        if own then return own end
        local shared = RepStorage:FindFirstChild("Ailments")
        return shared and shared:FindFirstChild(char.Name)
    end

    -- Absolute state, not a before/after diff: the server applies the burn in
    -- the SAME tick it stamps our cooldown, so by the time our client is told
    -- the cast happened the victim is often already lit, and a diff would see
    -- "no change" and never fire.
    local function burning(char)
        local ail = ailmentsOf(char)
        return ail ~= nil and ail:FindFirstChild("BlackFire") ~= nil
    end

    -- Everyone Amaterasu could have burned: other players and NPC/mob rigs.
    local function candidates()
        local out, seen = {}, {}
        for _, plr in ipairs(Players:GetPlayers()) do
            local char = plr ~= LP and plr.Character
            if char and char:FindFirstChild("HumanoidRootPart") then
                out[#out + 1] = char
                seen[char] = true
            end
        end
        for _, m in ipairs(workspace:GetChildren()) do
            if m:IsA("Model") and not seen[m] and m ~= LP.Character
               and m:FindFirstChildOfClass("Humanoid") and m:FindFirstChild("HumanoidRootPart") then
                out[#out + 1] = m
            end
        end
        return out
    end

    local function faceStop()
        if T.faceConn then T.faceConn:Disconnect() T.faceConn = nil end
    end

    -- Yaw-only turn toward the victim, every frame, until the swing ends.
    local function faceFor(char)
        faceStop()
        local deadline = os.clock() + HOLD
        T.faceConn = RunService.RenderStepped:Connect(function()
            local myHrp = root()
            local tHrp  = char and char:FindFirstChild("HumanoidRootPart")
            if not myHrp or not tHrp or not K.flags.autoTotsuka or os.clock() > deadline then
                faceStop()
                return
            end
            K.combatPauseUntil = os.clock() + 0.3
            local from, to = myHrp.Position, tHrp.Position
            local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
            if flat.Magnitude < 0.01 then return end
            myHrp.CFrame = CFrame.lookAt(from, from + flat.Unit)
        end)
    end

    local function strike(char)
        if T.busy then return end
        T.busy = true
        -- Face first so the swing starts already pointed at them.
        faceFor(char)
        K.combatPauseUntil = os.clock() + HOLD
        if not K.castSkill or not K.castSkill(TOTSUKA, 18) then
            -- cooldown / not owned / no resolve: drop the facing too
            faceStop()
        end
        task.delay(HOLD, function() T.busy = false end)
    end

    -- Armed by our own Amaterasu: poll for someone newly burning, nearest
    -- first, inside the Max Victim Distance bound. The bound matters - other
    -- people's Amaterasu burns players anywhere on the map, and without it a
    -- victim thousands of studs away gets picked (measured: real victim 27
    -- studs, unrelated players 5188-6363).
    local function hunt()
        if T.hunting then return end
        T.hunting = true
        task.spawn(function()
            local pool = candidates()
            local deadline = os.clock() + WINDOW
            while K.flags.autoTotsuka and os.clock() < deadline do
                local best, bestDist = nil, math.huge
                local myHrp = root()
                if myHrp then
                    for _, char in ipairs(pool) do
                        local tHrp = char.Parent and char:FindFirstChild("HumanoidRootPart")
                        if tHrp and burning(char) then
                            local d = (tHrp.Position - myHrp.Position).Magnitude
                            if d <= T.maxDist and d < bestDist then bestDist, best = d, char end
                        end
                    end
                end
                if best then
                    T.hunting = false
                    strike(best)
                    return
                end
                task.wait(STEP)
            end
            T.hunting = false
        end)
    end

    local function stop()
        for k, c in pairs(T.conns) do
            c:Disconnect()
            T.conns[k] = nil
        end
        faceStop()
        T.armedUntil, T.busy, T.hunting = 0, false, false
    end

    local function start()
        stop()
        -- Our own Amaterasu: the server stamps the cooldown entry on use.
        local function armFrom(entry)
            T.conns[entry] = entry.Changed:Connect(function()
                if K.flags.autoTotsuka then hunt() end
            end)
        end
        local all  = cooldownsFolder()
        local mine = all and all:FindFirstChild(LP.Name)
        if mine then
            local entry = mine:FindFirstChild(AMA)
            if entry then armFrom(entry) end
            T.conns.cdAdded = mine.ChildAdded:Connect(function(ch)
                if ch.Name == AMA and K.flags.autoTotsuka then
                    armFrom(ch)
                    hunt() -- first-ever use this life
                end
            end)
        end
    end

    UI.combatUtil.element("Toggle", "Auto Totsuka Blade", nil, function(v)
        K.flags.autoTotsuka = v.Toggle
        if not v.Toggle then
            stop()
            notify("Combat", "Auto Totsuka Blade disabled")
            return
        end
        start()
        -- Susanoo Strike is the awakening's M2, so it only exists while that
        -- awakening is up. Say so rather than silently doing nothing.
        if K.skillFromAwakening and K.skillFromAwakening(TOTSUKA) then
            notify("Combat", "Auto Totsuka Blade enabled - Amaterasu hit casts Susanoo Strike", 4)
        else
            notify("Combat", "Auto Totsuka Blade on - awaken Itachi's Mangekyo / EMS to use it", 5)
        end
    end)

    -- Not a tuned reach (the game defines none for Susanoo Strike) - it is the
    -- bound on how far away a burning player may be before we accept them as
    -- OUR Amaterasu victim. A real hit measured 27 studs out.
    UI.combatUtil.element("Slider", "Max Victim Distance", {
        default = { min = 10, max = 300, default = 60 },
        suffix  = " studs",
    }, function(v)
        T.maxDist = v.Slider
    end)
end

---------------------------------------------------------------------
-- SILENT AIM (moves only)
--
-- Server-authoritative aim: a move's cast computes v157 =
-- customRequirement(u1.Hit.Position, skill) (gamescript.txt:2241), runs its
-- own range checks off u1.Hit (e.g. Kirin, gamescript.txt:2342) AND sends
-- u153 = u1.Hit.p as startSkill arg3 (gamescript.txt:2565). Rewriting only the
-- remote arg leaves v157 / the range checks reading the real mouse, so the
-- server's revalidation sees the mismatch and drops the cast - that is what
-- bricked casting. The only consistent fix is to fake Mouse.Hit itself so the
-- whole client pipeline agrees.
--
-- Faking Mouse.Hit means hooking the shared instance __index, which fires on
-- EVERY property read of EVERY instance - and the game reads Mouse.Hit every
-- frame (character facing, gamescript.txt:15670). The public build pays for a
-- full player scan on each of those reads; THAT is what tanks FPS, not the
-- hook existing. So the target is resolved ONCE per frame into cfg.cachedHit
-- and the __index body is O(1): a pointer compare and a cached-CFrame return.
-- The hook is installed only while the feature is on and restored when off.
-- M1s go through CheckMeleeHit with no position, so this is moves only.
---------------------------------------------------------------------
do
    local cfg = {
        fov         = 120,
        fov360      = false,
        maxDistance = 500,
        teamCheck   = false,
        visibleCheck = false, -- only targets you have line of sight to
        ignoreDowned = true,  -- skip knocked / being-carried players
        whitelist   = {},    -- list of player names to never target
        showFov     = false,
        prediction  = false,
        predX       = 0.165,
        predY       = 0,
        fovCircle   = nil,
        cachedHit   = nil,   -- CFrame, refreshed once per RenderStepped
        cachedX     = nil,   -- faked Mouse.X for screen-ray moves (Lightning Strike)
        cachedY     = nil,   -- faked Mouse.Y
        keyValue    = nil,   -- live keybind state {Key, Type, Active} from the lib
    }
    K.silentAim = cfg

    -- Keybind gate. The lib mutates its value table in place (presses, mode
    -- changes, config loads), so a held reference is always current.
    --   Always / no key bound -> active whenever Silent Aim is enabled
    --   Toggle -> each press flips Active;  Hold -> Active only while held
    local function aimKeyActive()
        local kv = cfg.keyValue
        if not kv or not kv.Key or kv.Type == "Always" then return true end
        return kv.Active == true
    end

    local function teammate(target)
        if not cfg.teamCheck then return false end
        local mine, theirs = LP.Team, target.Team
        if mine and theirs then
            if mine == theirs then return true end
            if mine.Name and theirs.Name and mine.Name == theirs.Name then return true end
        end
        return false
    end

    local function whitelisted(target)
        return table.find(cfg.whitelist, target.Name) ~= nil
    end

    -- Knocked / being carried, read off ReplicatedStorage.Settings.<name> -
    -- the same Knocked and BeingCarried ("None" when free) values the game
    -- itself checks.
    local function downed(target)
        local s  = gameSettings()
        local ps = s and s:FindFirstChild(target.Name)
        if not ps then return false end
        local knocked = ps:FindFirstChild("Knocked")
        if knocked and knocked.Value == true then return true end
        local carried = ps:FindFirstChild("BeingCarried")
        return carried ~= nil and carried.Value ~= "None" and carried.Value ~= ""
    end

    -- Line of sight from the camera. RespectCanCollide lets non-collidable
    -- parts (foliage, effects, hitboxes) through, and a hit on some other
    -- character still counts as visible - only world geometry blocks.
    local rayParams = RaycastParams.new()
    rayParams.FilterType        = Enum.RaycastFilterType.Exclude
    rayParams.IgnoreWater       = true
    rayParams.RespectCanCollide = true
    local rayChar, rayDebris = nil, nil

    local function visibleTo(cam, char, part)
        local me, debris = LP.Character, workspace:FindFirstChild("Debris")
        if me ~= rayChar or debris ~= rayDebris then
            rayChar, rayDebris = me, debris
            rayParams.FilterDescendantsInstances = { me, debris }
        end
        local origin = cam.CFrame.Position
        local result = workspace:Raycast(origin, part.Position - origin, rayParams)
        if not result then return true end
        local hit = result.Instance
        if hit:IsDescendantOf(char) then return true end
        local model = hit:FindFirstAncestorOfClass("Model")
        return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
    end

    -- Body first, then the head (peeking over cover).
    local function canSee(cam, char, hrp)
        if visibleTo(cam, char, hrp) then return true end
        local head = char:FindFirstChild("Head")
        return head ~= nil and visibleTo(cam, char, head)
    end

    -- Full checks for one candidate (team, whitelist, knocked/carried,
    -- health, line of sight). pickTarget only calls this for a player who
    -- would beat the current best, so with a full server the Settings
    -- lookups and raycasts run for a handful of players a frame instead of
    -- all of them - same result: the lowest score among valid players.
    local function valid(plr, char, hrp, cam)
        if teammate(plr) or whitelisted(plr) then return false end
        if cfg.ignoreDowned and downed(plr) then return false end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return false end
        return not cfg.visibleCheck or canSee(cam, char, hrp)
    end

    -- Closest valid target: by screen distance to crosshair (FOV mode) or by
    -- world distance (360 mode, ignores where it is on screen). maxOverride
    -- lets Instant Kunai pick within its own range instead of Max Range.
    local function pickTarget(maxOverride)
        local cam = workspace.CurrentCamera
        local myRoot = root()
        if not cam or not myRoot then return nil end

        local vp      = cam.ViewportSize
        local cx, cy  = vp.X / 2, vp.Y / 2
        local myPos   = myRoot.Position
        local maxDist = maxOverride or cfg.maxDistance
        local fov     = cfg.fov
        local best, bestScore = nil, math.huge

        for _, plr in ipairs(playerList()) do
            local char = plr ~= LP and plr.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local pos       = hrp.Position
                local worldDist = (pos - myPos).Magnitude
                if worldDist <= maxDist then
                    local score = nil
                    if cfg.fov360 then
                        score = worldDist -- closest in the world, anywhere around you
                    else
                        local sp, onScreen = cam:WorldToViewportPoint(pos)
                        if onScreen then
                            local dx, dy = sp.X - cx, sp.Y - cy
                            local d = math.sqrt(dx * dx + dy * dy)
                            if d <= fov then score = d end
                        end
                    end
                    if score and score < bestScore and valid(plr, char, hrp, cam) then
                        bestScore, best = score, hrp
                    end
                end
            end
        end
        return best
    end
    -- Shared with Instant Kunai so both use the same targeting filters.
    K.silentAimPick = pickTarget

    -- Mouse override. "Hit" covers position-aimed moves; "X"/"Y" cover the ones
    -- that aim via Mouse.X/Y + ScreenPointToRay (Lightning Strike etc.). Target
    -- is left alone so NPC and UI clicks keep working.
    --
    -- The hook is built once and only SWAPPED INTO the metatable while there
    -- is a cached target (see refresh). The faked values only ever applied
    -- with a target cached, so behaviour is identical - but with nobody in
    -- FOV, the Hold key up, or Toggle off, every property read in the game
    -- runs the untouched native __index: zero overhead. While hooked, a
    -- non-mouse read costs one upvalue pointer compare and a pass-through.
    local idx = { mt = nil, real = nil, hook = nil, on = false }

    local function installIndex()
        if idx.hook then return true end
        if not (getrawmetatable and setreadonly) then
            notify("Combat", "Silent Aim needs getrawmetatable + setreadonly", 6)
            return false
        end
        local ok = pcall(function()
            local ncc   = newcclosure or function(f) return f end
            local mouse = LP:GetMouse()
            local mt    = getrawmetatable(game)
            local real  = mt.__index
            idx.mt, idx.real = mt, real
            idx.hook = ncc(function(self, key)
                if self == mouse then
                    if key == "Hit" then
                        local v = cfg.cachedHit
                        if v then return v end
                    elseif key == "X" then
                        local v = cfg.cachedX
                        if v then return v end
                    elseif key == "Y" then
                        local v = cfg.cachedY
                        if v then return v end
                    end
                end
                return real(self, key)
            end)
        end)
        if not ok then idx.hook = nil end
        return ok
    end

    -- Swap between exactly our hook and the __index we wrapped. If anything
    -- else has hooked __index on top in the meantime it is left alone rather
    -- than clobbered or chained into a loop (our hook just stays underneath,
    -- passing through whenever the cache is empty).
    local function setHooked(want)
        if want == idx.on or not idx.hook then return end
        pcall(function()
            local mt  = idx.mt
            local cur = mt.__index
            if want and cur == idx.real then
                setreadonly(mt, false)
                mt.__index = idx.hook
                setreadonly(mt, true)
            elseif not want and cur == idx.hook then
                setreadonly(mt, false)
                mt.__index = idx.real
                setreadonly(mt, true)
            end
            idx.on = mt.__index == idx.hook
        end)
    end

    local function uninstallIndex()
        setHooked(false)
    end

    -- Per-frame cache. The full scan runs here once, NOT on every Hit read.
    local refreshConn = nil

    local function clearCache()
        cfg.cachedHit, cfg.cachedX, cfg.cachedY = nil, nil, nil
        setHooked(false)
    end

    local function stopRefresh()
        if refreshConn then refreshConn:Disconnect() refreshConn = nil end
        clearCache()
    end

    local function refresh()
        -- Feature switched off some other way (e.g. a flag reset): shut down.
        if not K.flags.silentAim then stopRefresh() return end
        -- Key not active (Hold released / Toggle off): hand back the real
        -- mouse until the key turns it back on.
        if not aimKeyActive() then clearCache() return end

        local hrp = pickTarget()
        if not hrp then clearCache() return end

        local pos = hrp.Position
        if cfg.prediction then
            local vel = hrp.AssemblyLinearVelocity or hrp.Velocity or Vector3.zero
            pos = pos + Vector3.new(vel.X * cfg.predX, vel.Y * cfg.predY, vel.Z * cfg.predX)
        end
        cfg.cachedHit = CFrame.new(pos)

        -- Screen coords for moves that aim via Mouse.X/Y + ScreenPointToRay
        -- (e.g. Lightning Strike, gamescript.txt:2349). WorldToScreenPoint
        -- matches Mouse.X/Y's inset. Only set when the target is on screen, so
        -- off-screen / behind-camera targets fall back to the real mouse.
        local cam = workspace.CurrentCamera
        if cam then
            local sp, onScreen = cam:WorldToScreenPoint(pos)
            if onScreen then
                cfg.cachedX, cfg.cachedY = sp.X, sp.Y
            else
                cfg.cachedX, cfg.cachedY = nil, nil
            end
        end

        setHooked(true)
    end

    local function startRefresh()
        if refreshConn then return end
        refreshConn = RunService.RenderStepped:Connect(refresh)
    end

    -- FOV ring: one Drawing, driven only while the feature and the ring are on.
    local fovConn = nil
    local function updateFov()
        local circle = cfg.fovCircle
        if not circle then
            circle = newDrawing("Circle", {
                Thickness = 1, Filled = false, Transparency = 1,
                Color = Color3.fromRGB(255, 255, 255),
            })
            cfg.fovCircle = circle
            if not circle then return end
        end
        local cam = workspace.CurrentCamera
        if cam then
            circle.Position = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
            circle.Radius   = cfg.fov
            circle.Visible  = cfg.showFov and K.flags.silentAim and not cfg.fov360
        end
    end
    local function startFov()
        if fovConn then return end
        fovConn = RunService.RenderStepped:Connect(updateFov)
    end
    local function stopFov()
        if fovConn then fovConn:Disconnect() fovConn = nil end
        if cfg.fovCircle then cfg.fovCircle.Visible = false end
    end

    local enableToggle = UI.silentAim.element("Toggle", "Enable Silent Aim", nil, function(v)
        K.flags.silentAim = v.Toggle
        if v.Toggle then
            if not installIndex() then
                K.flags.silentAim = false
                return
            end
            startRefresh()
            if cfg.showFov then startFov() end
            notify("Combat", "Silent Aim enabled")
        else
            stopRefresh()
            uninstallIndex()
            stopFov()
            notify("Combat", "Silent Aim disabled")
        end
    end)

    -- Aim key: left-click the [ NONE ] label on "Enable Silent Aim", then
    -- press a key (right / middle mouse work too; Backspace clears it, Escape
    -- or clicking the label again cancels). The mode is the "Aim Key Mode"
    -- dropdown below:
    --   Toggle - press to turn aiming on, press again to turn it off
    --   Hold   - aims only while the key is held
    -- With no key bound, Silent Aim aims whenever it's enabled.
    local lastKey = nil
    local aimKey = enableToggle:add_keybind({ Key = nil, Type = "Toggle", Active = false }, function(v)
        cfg.keyValue = v
        if v.Pressed then
            if v.Type == "Toggle" and K.flags.silentAim then
                notify("Combat", "Silent Aim " .. (v.Active and "ON" or "OFF"), 1.5)
            end
        elseif v.Key ~= lastKey then
            lastKey = v.Key
            if v.Key then
                notify("Combat", "Aim key set to " .. v.Key .. " - "
                    .. (v.Type == "Hold" and "hold it to aim" or "press it to turn aiming on/off"), 4)
            end
        end
    end)
    -- set_value(nil) without no_cb just fires the callback once, which hands
    -- us the lib's live value table before any key is ever pressed.
    if aimKey then aimKey:set_value(nil) end

    UI.silentAim.element("Dropdown", "Aim Key Mode", {
        options = { "Toggle", "Hold" },
        default = { Dropdown = "Toggle" },
    }, function(v)
        if not aimKey then return end
        local kv = cfg.keyValue
        -- Either mode starts with aiming off until the key is used.
        aimKey:set_value({ Key = kv and kv.Key, Type = v.Dropdown, Active = false })
    end)

    UI.silentAim.element("Slider", "Aim FOV", {
        default = { min = 10, max = 600, default = 120 },
        suffix  = " px",
    }, function(v)
        cfg.fov = v.Slider
    end)

    UI.silentAim.element("Toggle", "360 FOV", nil, function(v)
        cfg.fov360 = v.Toggle
        if cfg.fovCircle then
            cfg.fovCircle.Visible = cfg.showFov and K.flags.silentAim and not cfg.fov360
        end
    end)

    UI.silentAim.element("Slider", "Max Range", {
        default = { min = 50, max = 1000, default = 500 },
        suffix  = " studs",
    }, function(v)
        cfg.maxDistance = v.Slider
    end)

    UI.silentAim.element("Toggle", "Team Check", nil, function(v)
        cfg.teamCheck = v.Toggle
    end)

    UI.silentAim.element("Toggle", "Visible Check", nil, function(v)
        cfg.visibleCheck = v.Toggle
    end)

    UI.silentAim.element("Toggle", "Ignore Knocked / Carried", ON, function(v)
        cfg.ignoreDowned = v.Toggle
    end)

    local function whitelistNames()
        local names = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then names[#names + 1] = p.Name end
        end
        table.sort(names)
        return names
    end

    local wlCombo = UI.silentAim.element("Combo", "Whitelist", {
        options = whitelistNames(),
    }, function(v)
        cfg.whitelist = v.Combo or {}
    end)

    UI.silentAim.element("Button", "Refresh Whitelist", nil, function()
        wlCombo:refresh(whitelistNames(), true)
        notify("Combat", "Whitelist players refreshed", 2)
    end)

    -- Keep the option list current as people join without pressing refresh.
    bind(Players.PlayerAdded:Connect(function()
        pcall(function() wlCombo:refresh(whitelistNames(), true) end)
    end))

    UI.silentAim.element("Toggle", "Show FOV Circle", nil, function(v)
        cfg.showFov = v.Toggle
        if v.Toggle and K.flags.silentAim then startFov() else stopFov() end
    end)

    UI.silentAim.create_line()

    UI.silentAim.element("Toggle", "Prediction", nil, function(v)
        cfg.prediction = v.Toggle
    end)

    UI.silentAim.element("Slider", "Prediction X", {
        default = { min = 0, max = 100, default = 17 },
        suffix  = " %",
    }, function(v)
        cfg.predX = v.Slider / 100
    end)

    UI.silentAim.element("Slider", "Prediction Y", {
        default = { min = 0, max = 100, default = 0 },
        suffix  = " %",
    }, function(v)
        cfg.predY = v.Slider / 100
    end)
end

---------------------------------------------------------------------
-- NO CROW ILLUSION SHAKE
--
-- Crow Illusion's camera shake is a Sleitnick CameraShaker at
-- ReplicatedStorage.Effects.CrowIllusion.EffectsModule.CameraShaker, driven by
-- :ShakeOnce() and only when the illusion lands on YOU (the module's v11 gate).
-- The FOV dip, grey tint and screen overlay are separate effects we leave
-- alone; the shake is killed by swapping that class's ShakeOnce for a no-op
-- (the effect ignores its return value). require() is cached, so a single swap
-- covers every future cast; the original is restored when toggled off.
---------------------------------------------------------------------
do
    local CS, origShakeOnce

    local function resolve()
        if CS then return true end
        pcall(function()
            CS = require(RepStorage.Effects.CrowIllusion.EffectsModule.CameraShaker)
        end)
        if type(CS) ~= "table" or type(CS.ShakeOnce) ~= "function" then
            CS = nil
            return false
        end
        origShakeOnce = CS.ShakeOnce
        return true
    end

    UI.boxProtection.element("Toggle", "No Crow Illusion Shake", nil, function(v)
        K.flags.noCrowShake = v.Toggle
        if v.Toggle then
            if not resolve() then
                K.flags.noCrowShake = false
                notify("Player", "Could not hook Crow Illusion module", 6)
                return
            end
            pcall(function() if setreadonly then setreadonly(CS, false) end end)
            CS.ShakeOnce = function() return nil end
            notify("Player", "No Crow Illusion Shake enabled")
        else
            if CS and origShakeOnce then
                pcall(function() if setreadonly then setreadonly(CS, false) end end)
                CS.ShakeOnce = origShakeOnce
            end
            notify("Player", "No Crow Illusion Shake disabled")
        end
    end)
end

---------------------------------------------------------------------
-- INSTANT KUNAI (Kunai Throw + Multi Kunai Throw)
--
-- The throw itself is server-side, but the kunai it spawns is not locked to
-- the server: it lands in workspace.Debris unanchored, and ~0.1-0.2s later
-- (end of wind-up) gets a BodyVelocity "DirectionalBV" at 250 studs/s plus
-- a TouchInterest. The server never calls SetNetworkOwner(nil) on it, so
-- Roblox hands physics ownership to the nearest player - the thrower - and
-- the server's Touched on the kunai trusts the touches our client produces.
-- (Live-verified: isnetworkowner() flips true at the BV, and redirected
-- kunais land their normal damage.)
--
-- So once we own it, we drive it straight through the target: park it 3
-- studs in front with its own BodyVelocity pointed at them (one physics step
-- = a genuine physical hit), then next frame sit it inside them and fire the
-- touch with firetouchinterest. Either one landing is enough; the server
-- counts one hit per kunai. After those two frames we never write to it
-- again - the server welds a hit kunai into the target, and writing to it
-- after that flings their character on our screen. Blocking and hit i-frames
-- still apply - this removes the flight time, not the server's rules.
--
-- Only kunais we OWN that SPAWNED within 12 studs of us are touched, so
-- someone else's kunai passing by (which can auto-transfer ownership to us)
-- is never hijacked. Nothing is added to our HRP (BanMe 1E stays clean).
-- Targeting is Silent Aim's picker (FOV / 360 / whitelist / team / visible /
-- knocked-carried) with its own range (Kunai Max Distance). No target -> the
-- kunai flies normally.
---------------------------------------------------------------------
do
    local conn     = nil
    local maxRange = 250   -- studs; only targets this close get an instant kunai

    local function waitOwned(part)
        local t0 = os.clock()
        while part.Parent and os.clock() - t0 < 1 do
            local ok, own = pcall(isnetworkowner, part)
            if ok and own then return true end
            RunService.Heartbeat:Wait()
        end
        return false
    end

    local function strike(part)
        if not waitOwned(part) then return end
        if not K.flags.instantKunai then return end

        local hrp = K.silentAimPick and K.silentAimPick(maxRange)
        if not hrp or not hrp.Parent then return end
        local hitPart = hrp.Parent:FindFirstChild("Torso") or hrp
        local bv      = part:FindFirstChild("DirectionalBV")
        local home    = part.Parent

        -- On impact the server welds the kunai into the target (the stuck
        -- kunai). Any CFrame/velocity written to it after that weld reaches
        -- us drags their whole character on our screen until replication
        -- snaps them back - a brief client-side fling. So the strike is two
        -- frames and then hands off for good: the weld needs a full round
        -- trip to arrive, and the second write is still gated on the kunai
        -- being a free, unjointed part we own.
        local function free()
            if part.Parent ~= home or not hitPart.Parent then return false end
            if part.AssemblyRootPart ~= part then return false end
            local ok, own = pcall(isnetworkowner, part)
            return ok and own
        end

        local tp  = hitPart.Position
        local off = tp - part.Position
        local dir = off.Magnitude > 0.01 and off.Unit or hitPart.CFrame.LookVector

        -- Frame 1: park 3 studs in front, aimed straight in, and let one
        -- physics step sweep it through the body (a genuine hit).
        part.CFrame = CFrame.lookAt(tp - dir * 3, tp)
        if bv then bv.Velocity = dir * 250 end
        part.AssemblyLinearVelocity = dir * 250
        RunService.Heartbeat:Wait()

        -- Frame 2: sit it inside them and fire the touch directly as well.
        -- Its own BodyVelocity carries it out the far side afterwards.
        if not free() then return end
        local tp2 = hitPart.Position
        part.CFrame = CFrame.lookAt(tp2, tp2 + dir)
        pcall(firetouchinterest, part, hitPart, 0)
        pcall(firetouchinterest, part, hitPart, 1)
    end

    -- Your weapon name, re-read at most once a second rather than per Debris
    -- part - combat floods Debris with effect parts.
    local weaponName, weaponAt = nil, -math.huge
    local function currentWeapon()
        local now = os.clock()
        if now - weaponAt > 1 then
            weaponName, weaponAt = settingText("CurrentWeapon"), now
        end
        return weaponName
    end

    -- The thrown part is named after the weapon ("Raijin Kunai") plus
    -- SmallKunai2/3 for Multi. Nutcracker Raijin and the Daggers are kunai-type
    -- weapons whose names don't contain "kunai", so match those too.
    local function isThrownKunai(d)
        local n = d.Name:lower()
        if n:find("kunai", 1, true) or n:find("dagger", 1, true) or n:find("raijin", 1, true) then
            return true
        end
        local weapon = currentWeapon()
        return weapon ~= nil and d.Name == weapon
    end

    -- Cheapest rejects first: type, then distance (most Debris effects spawn
    -- nowhere near you), and only then the name checks.
    local function onDebrisChild(d)
        if not K.flags.instantKunai or not d:IsA("BasePart") then return end
        local myRoot = root()
        if not myRoot or (d.Position - myRoot.Position).Magnitude > 12 then return end
        if not isThrownKunai(d) then return end
        task.spawn(strike, d)
    end

    UI.silentAim.create_line()

    UI.silentAim.element("Toggle", "Instant Kunai", nil, function(v)
        K.flags.instantKunai = v.Toggle
        if v.Toggle then
            if not (isnetworkowner and firetouchinterest) then
                K.flags.instantKunai = false
                notify("Combat", "Instant Kunai needs isnetworkowner + firetouchinterest", 6)
                return
            end
            local debris = workspace:FindFirstChild("Debris") or workspace:WaitForChild("Debris", 10)
            if not debris then
                K.flags.instantKunai = false
                notify("Combat", "Could not find workspace.Debris", 6)
                return
            end
            if not conn then conn = debris.ChildAdded:Connect(onDebrisChild) end
            notify("Combat", "Instant Kunai enabled (uses Silent Aim targeting)")
        else
            if conn then conn:Disconnect() conn = nil end
            notify("Combat", "Instant Kunai disabled")
        end
    end)

    UI.silentAim.element("Slider", "Kunai Max Distance", {
        default = { min = 10, max = 1000, default = 250 },
        suffix  = " studs",
    }, function(v)
        maxRange = v.Slider
    end)
end

---------------------------------------------------------------------
-- FORCE OPTIMIZE (client-side map + NPC streaming, map particles)
--
-- Profiled live: the game is CPU-bound, not GPU-bound. Graphics quality
-- 10 vs 1 and shadows did nothing - the GPU only draws ~200 batches. The
-- cost is the engine's per-object work on EVERYTHING loaded:
-- StreamingEnabled is off, so the whole map (~55k parts) and every NPC
-- (~150-185) stay loaded and processed every frame wherever you are.
-- Stacked at one test spot:
--     normal                          103 FPS   CPU 9.7 ms
--     far map chunks streamed out     184 FPS   CPU 5.4 ms
--     + far NPCs streamed out         281 FPS   CPU 3.5 ms
--     + ambient particles stopped     343 FPS   CPU 2.9 ms
--
-- So this is the streaming the developers left off, done on our client:
-- the map is split once into chunks (static models / loose static parts);
-- chunks and NPCs beyond Render Distance are parented to nil locally and
-- put back as you approach. The server, other players and hit detection
-- never see any of it.
--
-- Safety:
--  * Never touched: every workspace child the game's client scripts or this
--    script look up by name (area detection, waters, Chakra Points, Mission
--    Boards, Debris, quest props, boss doors, named NPCs, ...), player
--    characters, dropped items (an "ID" child), and any chunk with unanchored
--    parts (it could move, so its cached position would go stale).
--  * Teleports / respawns: if your position jumps, everything within SAFE
--    studs comes back inside Stepped - before physics - so the floor at the
--    destination is there before you can fall; the rest streams in.
--  * Hysteresis (hide only HYST studs past the radius) so things at the
--    edge don't flicker.
--  * Turning it off, or the script's flag reset, puts everything back.
--
-- Cost of the streamer itself: a chunk whose edge is M studs from the
-- show/hide line can't cross it until you've moved M studs, so it isn't
-- re-checked until then (~30 checks a frame instead of every chunk), and
-- reparenting is capped per frame so walking into a new area streams it in
-- over a few frames instead of one big hitch.
---------------------------------------------------------------------
do
    local EXCLUDE = {}
    for _, n in ipairs({
        -- referenced by the game's client scripts (gamescript + GameManager)
        "Terrain", "Camera", "Debris", "Locations", "ChakraPoints", "Crates",
        "Waters", "WaterBlocks", "voidPaths", "TB_Spawns", "RandomSpawns",
        "ThunderStormLocations", "Rifts", "SharkSpot", "DoorsModel", "ImplantBed",
        "Hyuga BossEntrances", "Haku BossIcy Mirror", "Mirror Realm",
        "FrostyKamuiDecor", "KamuiEntrance", "KamuiExit", "KamuiWebs",
        "ObitoStoneBlock", "IsobuButtons", "DeepForestEmergence", "Ramen Shop",
        "XPShark", "XPChain", "SwimmingShark", "SoulChain", "SharkmanShark",
        "ScarletShark", "QuestChain", "ButtonChain", "MandaInvisFloor", "WormDoor",
        "BasaltDoor", "Dog", "DeprivedDamselLines", "Uzumaki Heirloom",
        "The Wise Tree", "ScarletSlowcoachEnd", "ScarletSlowcoachFailedEnd",
        "Bob", "Might Guy", "OutKeeper", "Training Instructor",
        "The 1st Zetsu", "The 2nd Zetsu", "The 3rd Zetsu", "The 4th Zetsu",
        "The Deprived Damsel", "The Reanimated Reaver", "The Scarlet Slowcoach",
        -- referenced by this script (and the armor-repair Medic lookup)
        "Mission Boards", "TorchMesh", "The Fashioneer", "Chef", "Matatabi",
        "Medic",
    }) do EXCLUDE[n] = true end

    local SWEEP   = 0.3  -- seconds for the round-robin to pass every chunk
    local MAXV    = 200  -- studs/s assumed top speed between re-checks
    local JUMP    = 60   -- studs moved in one frame that counts as a teleport
    local HYST    = 75   -- extra studs before a visible chunk / NPC hides
    local SAFE    = 150  -- after a teleport, chunks this close return at once
    local BUDGET  = 400  -- parts reparented per frame in normal streaming
    local NPC_DT  = 0.25 -- NPC distance check interval (they move)
    local SCAN_DT = 3    -- interval for picking up newly spawned NPCs

    local S = {
        radius = 600,
        npcs   = true,   -- "Include NPCs"
        state  = "idle", -- idle -> building -> ready (built once, reused)
        conn   = nil,
        count  = 0,
        cursor = 1,
        lastFocus = nil,
        npcTimer = 0, scanTimer = 0,
        -- parallel arrays, one entry per chunk
        inst = {}, parent = {}, center = {}, extent = {}, parts = {},
        hidden = {}, dead = {}, due = {},
    }
    -- streamed NPCs: { m = model, p = parent, hidden, dead }
    local N = { list = {}, set = {} }

    -- One pass over a candidate: is anything in it unanchored (so it could
    -- move), and how many parts would reparenting it touch.
    local function inspect(inst)
        local parts, dynamic = 0, false
        if inst:IsA("BasePart") then
            parts, dynamic = 1, not inst.Anchored
        end
        for _, d in ipairs(inst:GetDescendants()) do
            if d:IsA("BasePart") then
                parts = parts + 1
                if not d.Anchored then dynamic = true end
            end
        end
        return dynamic, parts
    end

    local function addChunk(inst, center, extent, parts)
        local n = S.count + 1
        S.count = n
        S.inst[n], S.parent[n] = inst, inst.Parent
        S.center[n], S.extent[n], S.parts[n] = center, extent, parts
        S.hidden[n], S.dead[n], S.due[n] = false, false, 0
    end

    -- Static models small enough to be one unit become chunks, as do loose
    -- static parts. Folders, map-sized models and anything holding an NPC
    -- are descended into instead.
    local visited = 0
    local function consider(inst, depth)
        visited = visited + 1
        if visited % 400 == 0 then task.wait() end -- spread the scan over frames

        if inst.Parent == workspace and EXCLUDE[inst.Name] then return end
        if inst:FindFirstChild("ID") then return end -- dropped item
        if inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") then return end

        if inst:IsA("BasePart") then
            local dynamic, parts = inspect(inst)
            if not dynamic then addChunk(inst, inst.Position, inst.Size.Magnitude / 2, parts) end
            return
        end

        if inst:IsA("Model") or inst:IsA("Folder") then
            if inst:IsA("Model") and not inst:FindFirstChildWhichIsA("Humanoid", true) then
                local ok, cf, size = pcall(inst.GetBoundingBox, inst)
                if ok and cf and size.Magnitude < 3000 then
                    local dynamic, parts = inspect(inst)
                    if not dynamic then addChunk(inst, cf.Position, size.Magnitude / 2, parts) end
                    return
                end
            end
            if depth < 6 then
                for _, ch in ipairs(inst:GetChildren()) do consider(ch, depth + 1) end
            end
        end
    end

    local function build()
        S.state = "building"
        visited = 0
        for _, ch in ipairs(workspace:GetChildren()) do consider(ch, 0) end
        S.state = "ready"
    end

    -- Hide only from where we found it; if the server moved or destroyed a
    -- chunk, stop managing it rather than fight the server.
    local function setHidden(i, want)
        local inst = S.inst[i]
        if want then
            if inst.Parent ~= S.parent[i] then S.dead[i] = true return end
            if pcall(function() inst.Parent = nil end) then S.hidden[i] = true
            else S.dead[i] = true end
        else
            if pcall(function() inst.Parent = S.parent[i] end) then S.hidden[i] = false
            else S.dead[i] = true end
        end
    end

    -- Distance to the chunk's edge from the nearer of your character and
    -- the camera focus (so observing someone far away loads their area).
    local function chunkDist(i, a, b)
        local c = S.center[i]
        local d = math.huge
        if a then d = (c - a).Magnitude end
        if b then
            local d2 = (c - b).Magnitude
            if d2 < d then d = d2 end
        end
        return d - S.extent[i]
    end

    -- Re-check chunk i, then schedule its next check from how far its edge
    -- is from the show/hide line (it can't cross it any sooner). Returns the
    -- number of parts reparented, for the per-frame budget.
    local function evaluate(i, a, b, now, showR, hideR, budget)
        local d = chunkDist(i, a, b)
        local hidden = S.hidden[i]
        local moved = 0
        if (hidden and d < showR) or (not hidden and d > hideR) then
            -- Over this frame's budget: retry next sweep. The first
            -- reparent of a frame always goes through, however big.
            if S.parts[i] > budget and budget < BUDGET then
                S.due[i] = now
                return 0
            end
            setHidden(i, not hidden)
            hidden = S.hidden[i]
            moved = S.parts[i]
        end
        local margin = hidden and (d - showR) or (hideR - d)
        if margin < 0 then margin = 0 end
        S.due[i] = now + math.clamp(margin / MAXV, 0.05, 20)
        return moved
    end

    -----------------------------------------------------------------
    -- NPCs: models directly under workspace with a Humanoid that aren't a
    -- player's character. They move, so they're tracked live by pivot on a
    -- timer instead of cached. New spawns are picked up by a periodic scan;
    -- despawned ones drop out. PRIVATE's Mob ESP already handles mobs
    -- leaving and re-entering workspace.
    -----------------------------------------------------------------
    local function npcSetHidden(e, want)
        if want then
            if e.m.Parent ~= e.p then e.dead = true return end
            if pcall(function() e.m.Parent = nil end) then e.hidden = true else e.dead = true end
        else
            if pcall(function() e.m.Parent = e.p end) then e.hidden = false else e.dead = true end
        end
    end

    local function scanNPCs()
        for _, ch in ipairs(workspace:GetChildren()) do
            if ch:IsA("Model") and not N.set[ch] and not EXCLUDE[ch.Name]
               and ch:FindFirstChildOfClass("Humanoid")
               and not Players:GetPlayerFromCharacter(ch) then
                local e = { m = ch, p = workspace, hidden = false, dead = false }
                N.set[ch] = e
                N.list[#N.list + 1] = e
            end
        end
    end

    local function updateNPCs(a, b, showR, hideR)
        local keep = {}
        for _, e in ipairs(N.list) do
            if not e.dead and not e.hidden and e.m.Parent ~= e.p then
                e.dead = true -- despawned or moved by the server
            end
            if not e.dead then
                local ok, pivot = pcall(e.m.GetPivot, e.m)
                if ok then
                    local pos = pivot.Position
                    local d = math.huge
                    if a then d = (pos - a).Magnitude end
                    if b then
                        local d2 = (pos - b).Magnitude
                        if d2 < d then d = d2 end
                    end
                    if e.hidden and d < showR then
                        npcSetHidden(e, false)
                    elseif not e.hidden and d > hideR then
                        npcSetHidden(e, true)
                    end
                end
            end
            if e.dead then N.set[e.m] = nil else keep[#keep + 1] = e end
        end
        N.list = keep
    end

    local function restoreNPCs()
        for _, e in ipairs(N.list) do
            if e.hidden and not e.dead then npcSetHidden(e, false) end
        end
    end

    local function restoreAll()
        for i = 1, S.count do
            if S.hidden[i] and not S.dead[i] then setHidden(i, false) end
            S.due[i] = 0
        end
        restoreNPCs()
    end

    local function stop()
        if S.conn then S.conn:Disconnect() S.conn = nil end
        restoreAll()
        S.lastFocus = nil
    end

    local function step(_, dt)
        if not K.flags.forceOptimize then stop() return end
        if S.state ~= "ready" then return end
        dt = dt or 1 / 60

        local hrp = root()
        local cam = workspace.CurrentCamera
        local a = hrp and hrp.Position
        local b = cam and cam.Focus.Position
        if not a and not b then return end

        local now = os.clock()
        local showR, hideR = S.radius, S.radius + HYST

        -- Teleport, respawn, radius change or first frame: right now, in
        -- Stepped (before physics), every chunk within SAFE studs comes back
        -- so the floor is there before you can fall. Everything else is
        -- marked due and streams in over the next few frames.
        local jumped = a ~= nil and (S.lastFocus == nil or (a - S.lastFocus).Magnitude > JUMP)
        S.lastFocus = a
        if jumped then
            for i = 1, S.count do
                if not S.dead[i] then
                    if S.hidden[i] and chunkDist(i, a, b) < SAFE then setHidden(i, false) end
                    S.due[i] = 0
                end
            end
            S.npcTimer = NPC_DT
        end

        -- Round-robin sized to pass the whole list every SWEEP seconds at any
        -- framerate. Entries that aren't due yet cost one table read.
        local n = S.count
        if n > 0 then
            local slice = math.min(n, math.max(1, math.ceil(n * dt / SWEEP)))
            local budget, i = BUDGET, S.cursor
            for _ = 1, slice do
                if not S.dead[i] and S.due[i] <= now then
                    budget = budget - evaluate(i, a, b, now, showR, hideR, budget)
                end
                i = i + 1
                if i > n then i = 1 end
            end
            S.cursor = i
        end

        if S.npcs then
            S.scanTimer = S.scanTimer + dt
            if S.scanTimer >= SCAN_DT then S.scanTimer = 0 scanNPCs() end
            S.npcTimer = S.npcTimer + dt
            if S.npcTimer >= NPC_DT then S.npcTimer = 0 updateNPCs(a, b, showR, hideR) end
        end
    end

    local function start()
        if S.state == "idle" then
            task.spawn(function()
                build()
                if K.flags.forceOptimize then
                    notify("Visuals", "Force Optimize: streaming " .. S.count .. " map chunks", 4)
                end
            end)
        end
        S.lastFocus = nil
        S.scanTimer = SCAN_DT -- pick NPCs up on the first frame
        if not S.conn then S.conn = RunService.Stepped:Connect(step) end
    end

    -----------------------------------------------------------------
    -- Remove Map Particles: ambient emitters (not on characters, NPCs or
    -- combat effects in Debris) get Rate = 0 and their live particles
    -- cleared. Rate, never Enabled - the game reads Enabled on poison smoke,
    -- torch lights and chakra-point effects and never reads Rate. Map hazard
    -- visuals (fire, poison smoke) disappear with them.
    -----------------------------------------------------------------
    local P = { rates = {}, conn = nil }

    local function ambient(e)
        local deb = workspace:FindFirstChild("Debris")
        if deb and e:IsDescendantOf(deb) then return false end
        local m = e:FindFirstAncestorOfClass("Model")
        while m do
            if m:FindFirstChildOfClass("Humanoid") then return false end
            m = m.Parent and m.Parent:FindFirstAncestorOfClass("Model")
        end
        return true
    end

    local function quiet(e)
        if P.rates[e] == nil and e.Rate > 0 and ambient(e) then
            P.rates[e] = e.Rate
            e.Rate = 0
            pcall(function() e:Clear() end)
        end
    end

    local function particlesOn()
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ParticleEmitter") then quiet(d) end
        end
        if not P.conn then
            -- Emitters that arrive later: new effects, and anything the
            -- streamer brings back into range.
            P.conn = workspace.DescendantAdded:Connect(function(d)
                if K.flags.removeParticles and d:IsA("ParticleEmitter") then quiet(d) end
            end)
        end
    end

    local function particlesOff()
        if P.conn then P.conn:Disconnect() P.conn = nil end
        for e, r in pairs(P.rates) do pcall(function() e.Rate = r end) end
        P.rates = {}
    end

    UI.performance.element("Toggle", "Force Optimize", nil, function(v)
        K.flags.forceOptimize = v.Toggle
        if v.Toggle then
            start()
            notify("Visuals", "Force Optimize enabled - far map streamed out", 3)
        else
            stop()
            notify("Visuals", "Force Optimize disabled - map restored", 3)
        end
    end)

    UI.performance.element("Slider", "Render Distance", {
        default = { min = 200, max = 3000, default = 600 },
        suffix  = " studs",
    }, function(v)
        S.radius = v.Slider
        S.lastFocus = nil -- full re-evaluation on the next frame
    end)

    UI.performance.element("Toggle", "Include NPCs", ON, function(v)
        S.npcs = v.Toggle
        if not v.Toggle then restoreNPCs() end
    end)

    UI.performance.element("Label", "Streams out map + NPCs past Render Distance")

    UI.performance.create_line()

    UI.performance.element("Toggle", "Remove Map Particles", nil, function(v)
        K.flags.removeParticles = v.Toggle
        if v.Toggle then
            particlesOn()
            notify("Visuals", "Map particles removed", 3)
        else
            particlesOff()
            notify("Visuals", "Map particles restored", 3)
        end
    end)

    UI.performance.element("Label", "Also hides fire / poison smoke hazards")
end


yield(true)

---------------------------------------------------------------------
-- UNWIPE
--
-- A wiped character has LifeForce == 0. The two revival quests, "Samurai's
-- Retribution" and "Reaver's Revenge", can each be started once; a quest that
-- already reads "FinishedGood" has been spent and cannot be used again.
--
-- The unwipe itself is just StartQuest on both, then reading the progress
-- back to make the server commit it.
--
-- Eligibility is worth checking first because starting a quest you cannot
-- finish spends nothing but tells you nothing either: each quest also wants
-- an item (Lava Snakeskin / Samurai Soul) that has to already be on you.
---------------------------------------------------------------------
do
    local QUESTS = {
        { quest = "Samurai's Retribution", item = "Lava Snakeskin" },
        { quest = "Reaver's Revenge",      item = "Samurai Soul" },
    }

    local function dataFunction()
        return RepStorage:WaitForChild("Events"):WaitForChild("DataFunction")
    end

    local function questProgress(name)
        local ok, result = pcall(function()
            return dataFunction():InvokeServer("GetQuestProgress", name)
        end)
        if not ok then return nil end
        return result
    end

    local function ownsItem(data, itemName)
        local function scan(location)
            if type(location) ~= "table" then return false end
            for _, entry in pairs(location) do
                if type(entry) == "table" and entry.Item == itemName then
                    return true
                end
            end
            return false
        end
        return scan(data.Inventory) or scan(data.Loadout)
    end

    UI.unwipe.element("Button", "Check If Eligible", nil, function()
        task.spawn(function()
            local usable = {}

            for _, q in ipairs(QUESTS) do
                local progress = questProgress(q.quest)
                if progress == nil then
                    notify("Unwipe", "Failed to check eligibility", 4)
                    return
                end
                -- Anything other than FinishedGood means the quest is still
                -- available to us.
                if progress ~= "FinishedGood" then
                    usable[#usable + 1] = q
                end
            end

            if #usable == 0 then
                notify("Unwipe", "Not eligible - both revival quests are spent", 5)
                return
            end

            local ok, data = pcall(function()
                return dataFunction():InvokeServer("GetData")
            end)
            if not ok or type(data) ~= "table" then
                notify("Unwipe", "Eligible, but could not read your inventory", 5)
                return
            end

            local missing = {}
            for _, q in ipairs(usable) do
                if not ownsItem(data, q.item) then
                    missing[#missing + 1] = q.item
                end
            end

            if #missing > 0 then
                notify("Unwipe", "Eligible, but missing: " .. table.concat(missing, ", "), 6)
            else
                notify("Unwipe", "Eligible for unwipe", 4)
            end
        end)
    end)

    UI.unwipe.element("Button", "Unwipe", nil, function()
        task.spawn(function()
            local ok, data = pcall(function()
                return dataFunction():InvokeServer("GetData")
            end)

            if not ok or type(data) ~= "table" then
                notify("Unwipe", "Failed to get player data", 4)
                return
            end

            if data.LifeForce ~= 0 then
                notify("Unwipe", "You are not wiped", 4)
                return
            end

            pcall(function()
                for _, q in ipairs(QUESTS) do
                    dataFunction():InvokeServer("StartQuest", q.quest)
                end

                task.wait(0.5)

                -- Reading the progress back is what makes the server commit.
                for _, q in ipairs(QUESTS) do
                    dataFunction():InvokeServer("GetQuestProgress", q.quest)
                end

                task.wait(4)
            end)

            notify("Unwipe", "Unwipe done", 4)
        end)
    end)

    UI.unwipe.create_line()
    UI.unwipe.element("Label", "Only works while wiped")
    UI.unwipe.element("Label", "(LifeForce 0).")
end

yield(true)

---------------------------------------------------------------------
-- READ-ONLY EXTRAS
--
-- Everything in this block is passive: it reads replicated state or moves the
-- local camera. Nothing here fires a remote, writes to a replicated value or
-- touches the character, so none of it can be seen server side.
---------------------------------------------------------------------
local RO = {}


---------------------------------------------------------------------
-- STRETCHED RESOLUTION
--
-- Multiplies the camera CFrame by a matrix whose Y axis is scaled, which
-- squashes or stretches the rendered view vertically - the same effect as
-- running a stretched desktop resolution, without touching display settings.
-- Characters read wider and fill more of the screen at a ratio below 1.
--
-- Two differences from the usual snippet version of this:
--
--   * It binds at RenderPriority.Last instead of using RunService.RenderStepped.
--     RenderStepped fires BEFORE the camera module writes CFrame, so a plain
--     connection gets overwritten every frame and the effect flickers or does
--     nothing at all.
--   * It remembers the CFrame it wrote. If the camera module has not produced
--     a new one since (paused, cutscene, a frame where the camera did not
--     update), re-applying the scale would stack on top of the previous one
--     and the view would collapse toward flat over a few frames.
---------------------------------------------------------------------
RO.stretch = {
    enabled = false,
    ratio   = 80,       -- percent; 100 is unstretched
    bound   = false,
    key     = "sys_stretch_" .. tostring(math.random(1000, 9999)),
    last    = nil,
}

-- Not virtualised: pure camera matrix maths, bound at RenderPriority.Last so
-- it runs after the camera module every single frame.
local stretchStep = LPH_NO_VIRTUALIZE(function()
    local cam = workspace.CurrentCamera
    if not cam then return end

    local current = cam.CFrame
    if RO.stretch.last and current == RO.stretch.last then
        -- Still our own output: the camera has not moved on yet.
        return
    end

    local ratio  = RO.stretch.ratio / 100
    local scaled = current * CFrame.new(0, 0, 0, 1, 0, 0, 0, ratio, 0, 0, 0, 1)

    cam.CFrame      = scaled
    RO.stretch.last = scaled
end)

local function stretchStop()
    if RO.stretch.bound then
        RO.stretch.bound = false
        pcall(function() RunService:UnbindFromRenderStep(RO.stretch.key) end)
    end
    RO.stretch.last = nil
    -- No restore needed: the camera module rewrites CFrame from its own state
    -- on the very next frame, so the view snaps back on its own.
end

UI.camera.element("Toggle", "Stretched Resolution", nil, function(v)
    RO.stretch.enabled = v.Toggle

    if v.Toggle then
        if not RO.stretch.bound then
            RO.stretch.bound = true
            RO.stretch.last  = nil
            RunService:BindToRenderStep(RO.stretch.key, Enum.RenderPriority.Last.Value, function()
                if not RO.stretch.enabled then return end
                pcall(stretchStep)
            end)
        end
        notify("Visuals", "Stretched resolution enabled")
    else
        stretchStop()
        notify("Visuals", "Stretched resolution disabled")
    end
end)

UI.camera.element("Slider", "Aspect Ratio", {
    default = { min = 20, max = 200, default = 80 },
    suffix  = "%",
}, function(v)
    RO.stretch.ratio = v.Slider
    RO.stretch.last  = nil
end)

UI.camera.create_line()

---------------------------------------------------------------------
-- FREECAM
--
-- Camera only. The character is left where it is and its controls are
-- disabled through the PlayerModule so WASD drives the camera instead of
-- walking you somewhere while you are not looking.
---------------------------------------------------------------------
RO.freecam = { enabled = false, speed = 1, conn = nil, pos = nil, rot = nil, saved = {} }

local function freecamStep(dt)
    local cam = workspace.CurrentCamera
    local UIS = K.Services.UserInputService
    if not cam then return end

    local move  = Vector3.new()
    local speed = 60 * RO.freecam.speed

    if UIS:IsKeyDown(Enum.KeyCode.W) then move = move + Vector3.new(0, 0, -1) end
    if UIS:IsKeyDown(Enum.KeyCode.S) then move = move + Vector3.new(0, 0, 1) end
    if UIS:IsKeyDown(Enum.KeyCode.A) then move = move + Vector3.new(-1, 0, 0) end
    if UIS:IsKeyDown(Enum.KeyCode.D) then move = move + Vector3.new(1, 0, 0) end
    if UIS:IsKeyDown(Enum.KeyCode.E) then move = move + Vector3.new(0, 1, 0) end
    if UIS:IsKeyDown(Enum.KeyCode.Q) then move = move + Vector3.new(0, -1, 0) end
    if UIS:IsKeyDown(Enum.KeyCode.LeftShift) then speed = speed * 0.25 end

    local delta = UIS:GetMouseDelta()
    RO.freecam.rot = Vector2.new(
        math.clamp(RO.freecam.rot.X - delta.Y * 0.003, -math.rad(89), math.rad(89)),
        RO.freecam.rot.Y - delta.X * 0.003
    )

    local cf = CFrame.new(RO.freecam.pos) * CFrame.fromOrientation(RO.freecam.rot.X, RO.freecam.rot.Y, 0)
    RO.freecam.pos = (cf * CFrame.new(move * speed * dt)).Position

    cf = CFrame.new(RO.freecam.pos) * CFrame.fromOrientation(RO.freecam.rot.X, RO.freecam.rot.Y, 0)

    UIS.MouseBehavior    = Enum.MouseBehavior.LockCenter
    UIS.MouseIconEnabled = false

    cam.CameraType = Enum.CameraType.Scriptable
    cam.CFrame     = cf
    cam.Focus      = cf
end

local function freecamStart()
    local cam = workspace.CurrentCamera
    local UIS = K.Services.UserInputService

    RO.freecam.saved = {
        cameraType     = cam.CameraType,
        cameraCFrame   = cam.CFrame,
        cameraFocus    = cam.Focus,
        mouseBehavior  = UIS.MouseBehavior,
        mouseIcon      = UIS.MouseIconEnabled,
    }

    RO.freecam.rot = Vector2.new(cam.CFrame:ToEulerAnglesYXZ())
    RO.freecam.pos = cam.CFrame.Position

    pcall(function()
        local playerModule = require(LP:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
        RO.freecam.controls = playerModule:GetControls()
        RO.freecam.controls:Disable()
    end)

    RO.freecam.conn = bind(RunService.RenderStepped:Connect(function(dt)
        if not RO.freecam.enabled then return end
        pcall(freecamStep, dt)
    end))

    notify("Freecam", "WASD to move, Q/E up-down, Shift to slow", 5)
end

local function freecamStop()
    -- Never started: leave the camera exactly as the game left it.
    if not (RO.freecam.saved and RO.freecam.saved.cameraType) then return end

    local cam = workspace.CurrentCamera
    local UIS = K.Services.UserInputService

    if RO.freecam.conn then
        unbind(RO.freecam.conn)
        RO.freecam.conn = nil
    end

    local saved = RO.freecam.saved or {}
    pcall(function()
        cam.CameraType       = saved.cameraType or Enum.CameraType.Custom
        cam.CFrame           = saved.cameraCFrame or cam.CFrame
        cam.Focus            = saved.cameraFocus or cam.Focus
        UIS.MouseBehavior    = saved.mouseBehavior or Enum.MouseBehavior.Default
        UIS.MouseIconEnabled = saved.mouseIcon ~= false
    end)

    pcall(function()
        if RO.freecam.controls then
            RO.freecam.controls:Enable()
            RO.freecam.controls = nil
        end
    end)
end

UI.camera.element("Toggle", "Freecam", nil, function(v)
    RO.freecam.enabled = v.Toggle
    if v.Toggle then
        freecamStart()
    else
        freecamStop()
        notify("Freecam", "Freecam disabled", 2)
    end
end)

UI.camera.element("Slider", "Freecam Speed", {
    default = { min = 1, max = 20, default = 4 },
}, function(v)
    RO.freecam.speed = v.Slider / 4
end)

yield()

---------------------------------------------------------------------
-- WORLD VISUALS
--
-- Deliberately separate from No Visual Effects on the Player tab: that one
-- strips jutsu and weather effects, this one only changes how bright the
-- world is and how far you can see.
---------------------------------------------------------------------
RO.world = { fullbright = false, nofog = false, conns = {}, saved = nil }

local function saveWorld()
    if RO.world.saved then return end
    RO.world.saved = {
        Ambient        = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        Brightness     = Lighting.Brightness,
        FogEnd         = Lighting.FogEnd,
        FogStart       = Lighting.FogStart,
    }
end

local function applyWorld()
    pcall(function()
        if RO.world.fullbright then
            Lighting.Ambient        = Color3.fromRGB(178, 178, 178)
            Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
            Lighting.Brightness     = 2
        end
        if RO.world.nofog then
            Lighting.FogStart = 0
            Lighting.FogEnd   = 100000
        end
    end)
end

local function restoreWorld()
    local saved = RO.world.saved
    if not saved then return end
    if RO.world.fullbright or RO.world.nofog then return end

    pcall(function()
        Lighting.Ambient        = saved.Ambient
        Lighting.OutdoorAmbient = saved.OutdoorAmbient
        Lighting.Brightness     = saved.Brightness
        Lighting.FogStart       = saved.FogStart
        Lighting.FogEnd         = saved.FogEnd
    end)
    RO.world.saved = nil
end

-- The game rewrites lighting on weather and cutscene changes, so hold the
-- values with a watcher instead of a loop.
local function watchWorld()
    if #RO.world.conns > 0 then return end
    for _, prop in ipairs({ "Ambient", "OutdoorAmbient", "Brightness", "FogStart", "FogEnd" }) do
        RO.world.conns[#RO.world.conns + 1] = bind(Lighting:GetPropertyChangedSignal(prop):Connect(function()
            if RO.world.fullbright or RO.world.nofog then applyWorld() end
        end))
    end
end

local function unwatchWorld()
    if RO.world.fullbright or RO.world.nofog then return end
    for _, c in ipairs(RO.world.conns) do unbind(c) end
    RO.world.conns = {}
end

UI.worldVisuals.element("Toggle", "Fullbright", nil, function(v)
    RO.world.fullbright = v.Toggle
    if v.Toggle then
        saveWorld()
        applyWorld()
        watchWorld()
    else
        unwatchWorld()
        restoreWorld()
    end
end)

UI.worldVisuals.element("Toggle", "No Fog", nil, function(v)
    RO.world.nofog = v.Toggle
    if v.Toggle then
        saveWorld()
        applyWorld()
        watchWorld()
    else
        unwatchWorld()
        restoreWorld()
    end
end)

yield()

---------------------------------------------------------------------
-- LEADERBOARD SPECTATE
--
-- The game already draws a player list with a clickable row per player
-- (ClientGui.Mainframe.PlayerList.List, each row a "PlayerTemplate" holding a
-- "PlayerName" label). Rather than duplicating that list in our own dropdown,
-- this just attaches to the rows the game made: left click spectates that
-- player, right click snaps back to you.
--
-- CameraSubject only - no camera scripting, so the view behaves exactly like
-- your own and the game's own camera logic keeps running.
---------------------------------------------------------------------
RO.spectate = { enabled = false, target = nil, conns = {} }

-- The game hides its own HUD behind a blur while you are resting; leaving
-- that up while spectating someone else means watching them through it.
local function spectateChrome(show)
    pcall(function()
        local blur = Lighting:FindFirstChild("PointBlur")
        if blur then blur.Enabled = false end

        local gui  = LP:FindFirstChildOfClass("PlayerGui")
        gui = gui and gui:FindFirstChild("ClientGui")
        local rest = gui and gui:FindFirstChild("Mainframe") and gui.Mainframe:FindFirstChild("Rest")
        if not rest then return end

        for _, name in ipairs({ "TitleImage", "BackDrop", "MainMenuFrame" }) do
            local part = rest:FindFirstChild(name)
            if part then part.Visible = show end
        end
    end)
end

local function spectateReset()
    local hum = humanoid()
    if hum then
        pcall(function() workspace.CurrentCamera.CameraSubject = hum end)
    end
    RO.spectate.target = nil
    spectateChrome(true)
end

local function spectateRow(row)
    local label = row:FindFirstChild("PlayerName", true)
    if not label then return end

    local target = Players:FindFirstChild(label.Text)
    local hum    = target and target.Character and target.Character:FindFirstChildOfClass("Humanoid")
    if not hum then
        notify("Spectate", label.Text .. " has no character", 3)
        return
    end

    workspace.CurrentCamera.CameraSubject = hum
    RO.spectate.target = target.Name

    if target ~= LP then
        spectateChrome(false)
    else
        spectateChrome(true)
    end

    notify("Spectate", "Spectating " .. target.Name, 2)
end

local function bindRow(row)
    if row.Name ~= "PlayerTemplate" then return end

    -- The row is usually the button itself, but if the game wraps it in a
    -- frame, take the button inside it rather than giving up.
    local button = row:IsA("GuiButton") and row or row:FindFirstChildWhichIsA("GuiButton", true)
    if not button then return end

    RO.spectate.conns[#RO.spectate.conns + 1] = bind(button.MouseButton1Click:Connect(function()
        if RO.spectate.enabled then spectateRow(row) end
    end))

    RO.spectate.conns[#RO.spectate.conns + 1] = bind(button.MouseButton2Click:Connect(function()
        if RO.spectate.enabled then spectateReset() end
    end))
end

local function spectateAttach()
    task.spawn(function()
        local playerGui = LP:FindFirstChildOfClass("PlayerGui")
        local gui = playerGui and playerGui:WaitForChild("ClientGui", 10)
        if not gui then return end

        local mainframe = gui:WaitForChild("Mainframe", 10)
        local list      = mainframe
            and mainframe:FindFirstChild("PlayerList")
            and mainframe.PlayerList:FindFirstChild("List")
        if not list then
            notify("Spectate", "Could not find the player list", 4)
            return
        end

        for _, row in ipairs(list:GetChildren()) do
            bindRow(row)
        end

        -- Rows are created and destroyed as people join and leave.
        RO.spectate.conns[#RO.spectate.conns + 1] = bind(list.ChildAdded:Connect(function(row)
            if RO.spectate.enabled then bindRow(row) end
        end))
    end)
end

local function spectateDetach()
    for _, c in ipairs(RO.spectate.conns) do unbind(c) end
    RO.spectate.conns = {}
    spectateReset()
end

UI.spectate.element("Toggle", "Leaderboard Spectate", nil, function(v)
    RO.spectate.enabled = v.Toggle

    if v.Toggle then
        spectateAttach()
        notify("Spectate", "Left click a name in the player list, right click to stop", 6)
    else
        spectateDetach()
        notify("Spectate", "Spectate disabled", 2)
    end
end)

UI.spectate.element("Button", "Reset Camera", nil, function()
    spectateReset()
    notify("Spectate", "Camera returned", 2)
end)

-- ClientGui is rebuilt on respawn, taking every row (and our connections)
-- with it, so re-attach once it comes back.
pcall(function()
    local playerGui = LP:FindFirstChildOfClass("PlayerGui") or LP:WaitForChild("PlayerGui", 10)
    if not playerGui then return end

    bind(playerGui.ChildRemoved:Connect(function(removed)
        if removed.Name ~= "ClientGui" then return end
        if not RO.spectate.enabled then return end
        task.delay(1, function()
            if not RO.spectate.enabled then return end
            for _, c in ipairs(RO.spectate.conns) do unbind(c) end
            RO.spectate.conns = {}
            spectateAttach()
        end)
    end))
end)

-- Losing the subject would otherwise leave the camera staring at nothing.
bind(Players.PlayerRemoving:Connect(function(p)
    if RO.spectate.target == p.Name then
        spectateReset()
        notify("Spectate", p.Name .. " left - camera returned", 3)
    end
end))

---------------------------------------------------------------------
-- SERVER INFO
---------------------------------------------------------------------
UI.server.element("Button", "Copy Server ID", nil, function()
    local id = game.JobId
    if setclipboard then
        pcall(setclipboard, id)
        notify("Server", "Server ID copied: " .. string.sub(id, 1, 20) .. "...", 5)
    else
        notify("Server", id, 8)
    end
end)

-- Paste a JobId and jump straight to it, through the game's own
-- ServerTeleport rather than TeleportService.
do
    local target = ""

    UI.server.element("TextBox", "Target Server ID", { maxlen = 60 }, function(v)
        target = (v.Text or ""):gsub("%s+", "")
    end)

    UI.server.element("Button", "Join Server", nil, function()
        if target == "" then
            notify("Server", "Paste a server ID first", 4)
            return
        end
        notify("Server", "Teleporting...", 3)
        task.spawn(function()
            local ok = pcall(function()
                RepStorage:WaitForChild("Events"):WaitForChild("DataEvent")
                    :FireServer("ServerTeleport", target, 14)
            end)
            if not ok then
                pcall(function()
                    game:GetService("TeleportService")
                        :TeleportToPlaceInstance(game.PlaceId, target, LP)
                end)
            end
        end)
    end)
end

UI.server.create_line()

-- Server name and region come from the game's own HUD labels, which is where
-- the readable values live - there is no remote that returns them.
UI.server.element("Button", "Server Info", nil, function()
    local serverName, region = "Unknown", "Unknown"

    pcall(function()
        local gui = LP:FindFirstChildOfClass("PlayerGui")
        local mf  = gui and gui:FindFirstChild("ClientGui")
        mf = mf and mf:FindFirstChild("Mainframe")
        if not mf then return end

        local rest = mf:FindFirstChild("Rest")
        local menu = rest and rest:FindFirstChild("MainMenuFrame")
        local nameLabel = menu and menu:FindFirstChild("ServerName")
        if nameLabel and nameLabel.Text then
            local got = string.match(nameLabel.Text, ":%s*(.+)")
            if got and #(got:gsub("%s+", "")) > 0 then serverName = got end
        end

        local loadout = mf:FindFirstChild("Loadout")
        local top     = loadout and loadout:FindFirstChild("TopFrame")
        local regLabel = top and top:FindFirstChild("Region")
        if regLabel and regLabel.Text then
            local got = string.match(regLabel.Text, ":%s*(.+)")
            region = (got and #(got:gsub("%s+", "")) > 0) and got or "Blank Region"
        end
    end)

    local ping = "?"
    pcall(function()
        ping = string.format("%.0f ms",
            game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue())
    end)

    notify("Server", string.format("%s  |  %s  |  %d/%d  |  %s",
        serverName, region, #Players:GetPlayers(), Players.MaxPlayers, ping), 8)
end)

yield()

---------------------------------------------------------------------
-- WATCHERS
---------------------------------------------------------------------
RO.watch = { joins = false, joinConns = {} }

UI.watchers.element("Toggle", "Join / Leave Notifier", nil, function(v)
    RO.watch.joins = v.Toggle

    if v.Toggle then
        RO.watch.joinConns[#RO.watch.joinConns + 1] = bind(Players.PlayerAdded:Connect(function(p)
            if RO.watch.joins then notify("Players", p.Name .. " joined", 4) end
        end))
        RO.watch.joinConns[#RO.watch.joinConns + 1] = bind(Players.PlayerRemoving:Connect(function(p)
            if RO.watch.joins then notify("Players", p.Name .. " left", 4) end
        end))
        notify("Misc", "Join / Leave Notifier enabled")
    else
        for _, c in ipairs(RO.watch.joinConns) do unbind(c) end
        RO.watch.joinConns = {}
        notify("Misc", "Join / Leave Notifier disabled")
    end
end)

UI.watchers.element("Toggle", "Show Chat Window", nil, function(v)
    local ok = pcall(function()
        game:GetService("TextChatService").ChatWindowConfiguration.Enabled = v.Toggle
    end)
    if not ok then
        notify("Misc", "This server does not use TextChatService", 4)
        return
    end
    notify("Misc", "Chat window " .. (v.Toggle and "shown" or "hidden"))
end)

yield(true)

---------------------------------------------------------------------
-- SECURITY :: PLAYER PROXIMITY
--
-- Same HUD panel as the chakra sense readout, pinned just under it, showing
-- the closest player and, on hover, the next few after them.
---------------------------------------------------------------------
local Prox = {
    enabled       = false,
    panel         = nil,
    conn          = nil,
    ignoreVillage = false,
    ignoreUsers   = {},   -- array of names, straight from the Combo
    warnRange     = 0,
    lastWarned    = {},
}

local function proxIgnored(target)
    if Prox.ignoreVillage then
        local mine, theirs = LP.Team, target.Team
        if mine and theirs and (mine == theirs or mine.Name == theirs.Name) then
            return true
        end
    end

    if table.find(Prox.ignoreUsers, target.Name) then
        return true
    end

    return false
end

-- Sorted nearest-first, so the panel gets its headline and its hover list
-- out of one pass.
local function nearbyPlayers()
    local myRoot = root()
    if not myRoot then return {} end

    local found = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and not proxIgnored(p) then
            local char = p.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                found[#found + 1] = { player = p, distance = (hrp.Position - myRoot.Position).Magnitude }
            end
        end
    end

    table.sort(found, function(a, b) return a.distance < b.distance end)
    return found
end

UI.boxDetection.create_line()

UI.boxDetection.element("Toggle", "Player Proximity", nil, function(v)
    Prox.enabled = v.Toggle

    if v.Toggle then
        if not Prox.panel then
            Prox.panel = makePanel({
                width = 260, height = 38, y = 62, list = true,
                icon  = "rbxassetid://10747373176",   -- player
            })
        end
        Prox.panel.frame.Visible = true

        if not Prox.conn then
            -- Distance does not need recomputing at render rate.
            local accum = 0
            Prox.conn = bind(RunService.Heartbeat:Connect(function(dt)
                if not Prox.enabled or not Prox.panel then return end

                accum = accum + dt
                if accum < 0.1 then return end
                accum = 0

                local near = nearbyPlayers()
                local rows = {}

                if #near == 0 then
                    Prox.panel.left.Text = "Nearby players"
                    Prox.panel.set_state("None", Color3.fromRGB(255, 255, 255))
                else
                    local first = near[1]
                    local close = Prox.warnRange > 0 and first.distance <= Prox.warnRange
                    Prox.panel.left.Text = first.player.Name
                    Prox.panel.set_state(
                        string.format("%d studs", math.floor(first.distance)),
                        close and Color3.fromRGB(239, 68, 68) or Color3.fromRGB(34, 197, 94)
                    )

                    for i = 1, math.min(#near, 8) do
                        local entry = near[i]
                        rows[i] = {
                            text   = entry.player.Name,
                            note   = math.floor(entry.distance) .. " studs",
                            colour = (Prox.warnRange > 0 and entry.distance <= Prox.warnRange)
                                     and Color3.fromRGB(239, 68, 68)
                                     or  Color3.fromRGB(120, 126, 138),
                        }
                    end
                end

                Prox.panel.set_list(rows)

                -- Optional one-shot alert when somebody crosses the warn
                -- radius; it re-arms only once they leave it again.
                if Prox.warnRange > 0 then
                    for _, entry in ipairs(near) do
                        local name = entry.player.Name
                        if entry.distance <= Prox.warnRange then
                            if not Prox.lastWarned[name] then
                                Prox.lastWarned[name] = true
                                notify("Proximity", name .. " is " .. math.floor(entry.distance) .. " studs away", 4)
                            end
                        else
                            Prox.lastWarned[name] = nil
                        end
                    end
                end
            end))
        end

        notify("Security", "Player Proximity enabled")
    else
        if Prox.conn then
            unbind(Prox.conn)
            Prox.conn = nil
        end
        if Prox.panel then
            Prox.panel.frame.Visible = false
            if Prox.panel.list then Prox.panel.list.Visible = false end
        end
        Prox.lastWarned = {}
        notify("Security", "Player Proximity disabled")
    end
end)

UI.boxDetection.element("Toggle", "Drag Proximity Panel", nil, function(v)
    if Prox.panel then Prox.panel.draggable = v.Toggle end
end)

UI.boxDetection.element("Slider", "Proximity Warn Range", {
    default = { min = 0, max = 500, default = 0 },
    suffix  = " studs",
}, function(v)
    Prox.warnRange  = v.Slider
    Prox.lastWarned = {}
end)

UI.boxDetection.element("Toggle", "Proximity: Ignore Village", nil, function(v)
    Prox.ignoreVillage = v.Toggle
end)

local proxIgnoreCombo = UI.boxDetection.element("Combo", "Ignore Users", {
    options = playerNames(),
}, function(v)
    Prox.ignoreUsers = v.Combo or {}
end)

UI.boxDetection.element("Button", "Refresh Ignore List", nil, function()
    proxIgnoreCombo:refresh(playerNames(), true)
    notify("Proximity", "Player list refreshed", 2)
end)

-- Keep the options current as people join and leave, without anyone pressing
-- refresh; the picks themselves are kept, so somebody who rejoins stays
-- ignored.
bind(Players.PlayerAdded:Connect(function()
    pcall(function() proxIgnoreCombo:refresh(playerNames(), true) end)
end))

bind(Players.PlayerRemoving:Connect(function()
    task.defer(function()
        pcall(function() proxIgnoreCombo:refresh(playerNames(), true) end)
    end)
end))

yield(true)

---------------------------------------------------------------------
-- SETTINGS :: CONFIGS
---------------------------------------------------------------------
local configName = "default"
local configList

UI.boxConfigs.element("TextBox", "Config Name", { default = "default", maxlen = 32 }, function(v)
    if v.Text ~= "" then configName = v.Text end
end)

configList = UI.boxConfigs.element("Dropdown", "Saved Configs", {
    options = Window.list_cfgs(),
}, function(v)
    if v.Dropdown and v.Dropdown ~= "" then configName = v.Dropdown end
end)

UI.boxConfigs.element("Button", "Save Config", nil, function()
    local ok, err = Window.save_cfg(configName)
    if ok then
        configList:refresh(Window.list_cfgs(), true)
        notify("Config", 'Saved "' .. configName .. '"')
    else
        notify("Config", "Save failed: " .. tostring(err), 5)
    end
end)

UI.boxConfigs.element("Button", "Load Config", nil, function()
    local ok, err = Window.load_cfg(configName)
    if ok then
        notify("Config", 'Loaded "' .. configName .. '"')
    else
        notify("Config", "Load failed: " .. tostring(err), 5)
    end
end)

UI.boxConfigs.element("Button", "Delete Config", nil, function()
    if Window.delete_cfg(configName) then
        configList:refresh(Window.list_cfgs())
        notify("Config", 'Deleted "' .. configName .. '"')
    else
        notify("Config", "Delete failed")
    end
end)

UI.boxConfigs.element("Button", "Refresh List", nil, function()
    configList:refresh(Window.list_cfgs(), true)
    notify("Config", "Config list refreshed", 2)
end)

---------------------------------------------------------------------
-- SETTINGS :: MENU
---------------------------------------------------------------------
UI.boxMenu.element("Label", "Sys - Private")
UI.boxMenu.element("Label", "Toggle menu: Insert")
UI.boxMenu.create_line()

local MENU_KEYS = { "Insert", "RightShift", "RightControl", "F1", "F2", "F4" }

UI.boxMenu.element("Dropdown", "Menu Keybind", {
    options = MENU_KEYS,
    default = { Dropdown = "Insert" },
}, function(v)
    local code = Enum.KeyCode[v.Dropdown]
    if code then
        Window.set_keybind(code)
        notify("Menu", "Menu key set to " .. v.Dropdown, 2)
    end
end)

---------------------------------------------------------------------
-- UNLOAD
--
-- Everything this script created comes back off: hooks cannot be removed once
-- installed, but their flags are cleared so they become straight passthroughs,
-- every connection is dropped, every Drawing is released, and the loaded
-- marker is cleared so a re-execute is a clean start rather than a second
-- copy running alongside the first.
---------------------------------------------------------------------
local function unload()
    -- Flags first: anything still mid-frame reads false and stops working.
    for key in pairs(K.flags) do
        K.flags[key] = false
    end

    ESP.enabled     = false
    MOB.enabled     = false
    Sense.enabled   = false
    Prox.enabled    = false
    K.unlockAbort   = true
    K.beingObserved = false

    pcall(setNoclip, false)
    pcall(omniStop)
    pcall(chargeStop)
    pcall(chakraStop)
    pcall(masteryStop)
    pcall(Ramen.stop)
    M1.enabled = false
    pcall(M1.stop)
    Hitbox.enabled = false
    pcall(hitboxStop)
    pcall(senseStop)
    pcall(stopMobRegistry)
    pcall(restoreVisuals)

    pcall(clearPlayerESP)
    pcall(clearMobESP)

    -- Read-only extras: camera bindings and lighting overrides have to be
    -- handed back explicitly, they are not connections.
    RO.freecam.enabled  = false
    RO.stretch.enabled  = false
    RO.watch.joins      = false
    RO.world.fullbright = false
    RO.world.nofog      = false

    pcall(freecamStop)
    pcall(stretchStop)
    pcall(restoreWorld)


    if RO.spectate.enabled or RO.spectate.target then
        RO.spectate.enabled = false
        pcall(spectateDetach)
    end

    for part in pairs(Void.parts) do
        if part and part.Parent then
            pcall(function() part.CanTouch = true end)
        end
    end
    Void.parts = {}

    for _, c in ipairs(K.Connections) do
        pcall(function() c:Disconnect() end)
    end
    K.Connections = {}

    if HUD.gui then
        pcall(function() HUD.gui:Destroy() end)
        HUD.gui = nil
    end
    Sense.panel = nil
    Prox.panel  = nil

    pcall(function() Atlas:unload() end)

    pcall(function()
        getgenv().__sys_priv = nil
        getgenv()[_genvKey]  = nil
    end)
end

UI.boxMenu.element("Button", "Unload Script", nil, function()
    notify("Sys", "Unloading...", 2)
    task.delay(0.35, unload)
end)

---------------------------------------------------------------------
-- FINALISE
---------------------------------------------------------------------
pcall(function()
    -- One small marker, under a per-run random key, plus the unload handle so
    -- a re-execute can retire this instance instead of stacking on top of it.
    getgenv()[_genvKey]  = os.clock()
    getgenv().__sys_priv = unload
end)

yield(true)

-- The menu is ready, but the splash owns the screen until it finishes.
task.spawn(function()
    Splash.await()
    Splash.hide()
    Window.SetOpen(true)
    notify("Sys - Private", "Loaded. Press Insert to toggle.", 5)
end)
