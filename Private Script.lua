--[[
    Kyo - Private
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
    local ok, existing = pcall(function() return getgenv().__kyo_priv end)
    if ok and existing then
        -- Already running: ask the live instance to unload, then bail.
        pcall(function() getgenv().__kyo_priv() end)
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
    local GuiService       = game:GetService("GuiService")
    local LocalPlayer      = K.LocalPlayer
    local Mouse            = LocalPlayer:GetMouse()

    local ACCENT     = Color3.fromRGB(152, 84, 255)
    local ACCENT_DIM = Color3.fromRGB(92, 46, 168)
    local IDLE       = Color3.fromRGB(150, 150, 150)
    local HOVER      = Color3.fromRGB(255, 255, 255)
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
    local keybinds     = {}   -- [n] = {value = {...}, cb = fn, bind = fn}
    local binding_slot = nil  -- the keybind currently capturing a key

    local function key_name(input)
        return input.KeyCode.Name ~= "Unknown" and input.KeyCode.Name or input.UserInputType.Name
    end

    track(UserInputService.InputBegan:Connect(function(input, processed)
        if binding_slot then
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
                slot.cb(v)
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

        cfg_folder = cfg_folder or "KyoPrivate"

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
            Visible                = true,
        }, ScreenGui)

        -- The GUI ignores the topbar inset, so the cursor has to add it back.
        -- The public source hardcoded +36, which is only correct on one screen
        -- configuration - GetGuiInset() is the real offset.
        local cursor_conn
        local function start_cursor()
            if cursor_conn then return end
            cursor_conn = track(RunService.RenderStepped:Connect(function()
                local pos    = UserInputService:GetMouseLocation()
                local inset  = GuiService:GetGuiInset()
                Cursor.Position = UDim2.fromOffset(pos.X + inset.X, pos.Y + inset.Y)
            end))
        end
        local function stop_cursor()
            if not cursor_conn then return end
            pcall(function() cursor_conn:Disconnect() end)
            cursor_conn = nil
        end
        start_cursor()

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
                                warn("[Kyo] element callback error (" .. tostring(flag) .. "): " .. tostring(err))
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
                                }

                                slot.bind = function(pressed)
                                    if pressed == "Backspace" then
                                        extra_value.Key = nil
                                        Keybind.Text    = "[ NONE ]"
                                    else
                                        extra_value.Key = pressed
                                        Keybind.Text    = "[ " .. pressed:upper() .. " ]"
                                    end
                                    Keybind.Size = UDim2.new(0, lib:text_size(Keybind.Text, 14).X + 3, 0, 20)
                                    slot.cb(extra_value)
                                end

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
                                        extra_value.Active   = (mode ~= "Hold")

                                        for _, other in ipairs(KeybindFrame:GetChildren()) do
                                            if other:IsA("TextButton") then
                                                lib:tween(other, {TextColor3 = (other.Name == mode) and ACCENT or IDLE})
                                            end
                                        end
                                        slot.cb(extra_value)
                                    end))
                                end

                                track(Keybind.MouseButton1Down:Connect(function()
                                    if binding_slot then return end
                                    Keybind.Text = "[ ... ]"
                                    Keybind.Size = UDim2.new(0, lib:text_size("[ ... ]", 14).X + 3, 0, 20)
                                    -- Defer one frame: this very click would otherwise be captured.
                                    task.defer(function() binding_slot = slot end)
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

local Window = Atlas.new("Kyo - Private", "KyoPrivate/Bloodlines")

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

-- Visuals
UI.secVisPlayers     = TabVisuals.new_section("Players")
UI.boxPlayerESP      = UI.secVisPlayers.new_sector("Player ESP", "Left")
UI.boxPlayerESPOpt   = UI.secVisPlayers.new_sector("Options", "Right")

UI.secVisMobs        = TabVisuals.new_section("Mobs")
UI.boxMobESP         = UI.secVisMobs.new_sector("Mob ESP", "Left")
UI.boxMobESPOpt      = UI.secVisMobs.new_sector("Options", "Right")

UI.secWorld          = TabVisuals.new_section("World")
UI.itemESP           = UI.secWorld.new_sector("Item ESP", "Left")
UI.camera            = UI.secWorld.new_sector("Camera", "Right")
UI.worldVisuals      = UI.secWorld.new_sector("World Visuals", "Left")

-- Teleports
UI.secTpLocations    = TabTeleports.new_section("Locations")
UI.boxChakraPoints   = UI.secTpLocations.new_sector("Chakra Points", "Left")
UI.boxFruits         = UI.secTpLocations.new_sector("Fruits", "Right")

UI.secTpPlayers      = TabTeleports.new_section("Players")
UI.boxTpPlayer       = UI.secTpPlayers.new_sector("Teleport to Player", "Left")

-- Misc
UI.secMiscData       = TabMisc.new_section("Data")
UI.boxViewData       = UI.secMiscData.new_sector("View Data", "Left")
UI.boxPurchase       = UI.secMiscData.new_sector("Purchase", "Right")

UI.secUtility        = TabMisc.new_section("Utility")
UI.spectate          = UI.secUtility.new_sector("Spectate", "Left")
UI.server            = UI.secUtility.new_sector("Server", "Right")
UI.watchers          = UI.secUtility.new_sector("Watchers", "Left")

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
local _settingsCache, _settingsCacheTime = nil, 0

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
    method           = "V1",   -- V1 = Drawing overlay, V2 = BillboardGui
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
    showArrows       = false,
    teamCheck        = false,

    maxCooldowns     = 3,
    arrowOffset      = 150,
    arrowSize        = 15,

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
    arrowColor       = Color3.fromRGB(152, 84, 255),
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

-- Assigned by the V2 block further down. Declared here so the shared render
-- loop can call into it without the two halves having to be interleaved.
local renderV2, clearV2, hideV1Labels

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

local function healthColor(pct)
    pct = math.clamp(pct, 0, 1)
    if pct >= 0.5 then
        return lerpColor(HP_MID, HP_HIGH, (pct - 0.5) * 2)
    end
    return lerpColor(HP_LOW, HP_MID, pct * 2)
end

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

local function hideDrawings(data)
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
end

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

        -- Triangle is not implemented by every executor, so this may come
        -- back nil; every use of it is guarded.
        Arrow       = newDrawing("Triangle", {Thickness = 1, Filled = true, Color = Color3.fromRGB(152, 84, 255), Visible = false}),

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

local function clearPlayerESP()
    for _, data in pairs(espObjects) do destroyDrawings(data) end
    espObjects = {}
end

local function clearMobESP()
    for _, data in pairs(mobObjects) do destroyDrawings(data) end
    mobObjects = {}
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
    local folder = RepStorage:FindFirstChild("Cooldowns")
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
local function drawBar(bg, fill, barX, barY, barW, barH, pct, color)
    bg.Visible  = true
    bg.Position = Vector2.new(barX, barY)
    bg.Size     = Vector2.new(barW, barH)

    local fillH = math.max(1, barH * math.clamp(pct, 0, 1))
    fill.Visible  = true
    fill.Position = Vector2.new(barX, barY + (barH - fillH))
    fill.Size     = Vector2.new(barW, fillH)
    fill.Color    = color
end

local function hideBar(bg, fill)
    bg.Visible   = false
    fill.Visible = false
end

---------------------------------------------------------------------
-- OFF-SCREEN ARROWS
--
-- Direction is taken in camera object space, so a target in front of the
-- camera (negative Z) puts the arrow at the top of the ring and one behind
-- puts it at the bottom, with no special casing for the wrap-around.
---------------------------------------------------------------------
local function drawArrow(arrow, cam, worldPos, color, offset, size)
    if not arrow then return end

    local rel = cam.CFrame:PointToObjectSpace(worldPos)
    local flat = Vector2.new(rel.X, rel.Z)
    if flat.Magnitude < 0.001 then
        arrow.Visible = false
        return
    end

    local dir    = flat.Unit
    local centre = cam.ViewportSize / 2
    local at     = centre + dir * offset
    local perp   = Vector2.new(-dir.Y, dir.X)

    arrow.Visible = true
    arrow.Color   = color
    arrow.PointA  = at + dir * size
    arrow.PointB  = at - dir * size * 0.5 + perp * size * 0.6
    arrow.PointC  = at - dir * size * 0.5 - perp * size * 0.6
end

local function tracerOrigin(mode, viewport)
    if mode == "Top" then
        return Vector2.new(viewport.X / 2, 0)
    elseif mode == "Center" then
        return Vector2.new(viewport.X / 2, viewport.Y / 2)
    end
    return Vector2.new(viewport.X / 2, viewport.Y)
end

---------------------------------------------------------------------
-- PLAYER ESP RENDER
---------------------------------------------------------------------
local function renderPlayerESP()
    if not ESP.enabled then return end

    local cam = workspace.CurrentCamera
    if not cam then return end

    local myRoot = root()
    local myPos  = myRoot and myRoot.Position
    local W2VP   = cam.WorldToViewportPoint

    for _, target in ipairs(Players:GetPlayers()) do
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
            -- Off screen: everything hides except the arrow, which is the
            -- whole point of the arrow.
            hideDrawings(data)
            if ESP.showArrows then
                drawArrow(data.Arrow, cam, hrp.Position,
                    isTeammate(target) and ESP.teamColor or ESP.arrowColor,
                    ESP.arrowOffset, ESP.arrowSize)
            end
            continue
        end

        if data.Arrow then data.Arrow.Visible = false end

        local team      = isTeammate(target)
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

        -- Boxes, tracers, arrows and the highlight are shared by both
        -- methods - only the text and the bars differ, and in V2 those are
        -- billboards instead of Drawings.
        if ESP.method ~= "V1" then
            if ESP.showTracers then
                data.Tracer.Visible = true
                data.Tracer.From    = tracerOrigin(ESP.tracerOrigin, cam.ViewportSize)
                data.Tracer.To      = Vector2.new(rootPos.X, rootPos.Y)
                data.Tracer.Color   = team and ESP.teamColor or ESP.tracerColor
            else
                data.Tracer.Visible = false
            end

            if ESP.showHighlight then
                if not data.Highlight then
                    local hl = Instance.new("Highlight")
                    hl.Name                = K.Services.HttpService:GenerateGUID(false)
                    hl.FillTransparency    = 0.65
                    hl.OutlineTransparency = 0
                    hl.Adornee             = char
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

            continue
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
            local pct = bloodPct(target)
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
            if ESP.showClan then
                local clan = bloodlineOf(target)
                if clan then label = label .. " [" .. clan .. "]" end
            end

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

        -- One status row carries freshie / awakened / current skill so the
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

        if ESP.showCombatTimer then
            local timer = combatTimerOf(target)
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
            local list = cooldownsOf(target, ESP.maxCooldowns)
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
        if ESP.showTracers then
            data.Tracer.Visible = true
            data.Tracer.From    = tracerOrigin(ESP.tracerOrigin, cam.ViewportSize)
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
end

---------------------------------------------------------------------
-- MOB REGISTRY
--
-- Mobs are Models sitting directly under workspace with a Humanoid, that are
-- not a player character and are not a Dialog (quest/shop) NPC. The Dialog
-- test is cached per model: it never changes and the check is not free.
---------------------------------------------------------------------
local mobRegistry  = {}
local dialogCache  = {}
local mobConns     = {}

local function isPlayerModel(model)
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character == model then return true end
    end
    return false
end

local function isMob(model)
    if not model:IsA("Model") then return false end
    if model.Parent ~= workspace then return false end
    if not model:FindFirstChildOfClass("Humanoid") then return false end
    if not (model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso")) then return false end
    if isPlayerModel(model) then return false end

    local cached = dialogCache[model]
    if cached ~= nil then return not cached end

    local tag = model:FindFirstChild("NPC")
    local hasDialog = (tag and tag:IsA("StringValue") and tag.Value == "Dialog") or false
    dialogCache[model] = hasDialog
    return not hasDialog
end

local function startMobRegistry()
    mobRegistry = {}

    for _, obj in ipairs(workspace:GetChildren()) do
        if isMob(obj) then mobRegistry[obj] = true end
    end

    mobConns[#mobConns + 1] = bind(workspace.ChildAdded:Connect(function(obj)
        if not MOB.enabled then return end
        -- Humanoid is often parented a frame or two after the model.
        task.delay(0.5, function()
            if not MOB.enabled or not obj.Parent then return end
            if isMob(obj) then mobRegistry[obj] = true end
        end)
    end))

    mobConns[#mobConns + 1] = bind(workspace.ChildRemoved:Connect(function(obj)
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
    mobConns    = {}
    mobRegistry = {}
    dialogCache = {}
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

local function renderMobESP()
    if not MOB.enabled then return end

    mobFrame = mobFrame + 1
    if mobFrame % 3 ~= 0 then return end

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
end

---------------------------------------------------------------------
-- RENDER LOOP (one connection shared by both ESPs)
---------------------------------------------------------------------
local function syncEspLoop()
    local wanted = ESP.enabled or MOB.enabled

    if wanted and not espConn then
        espConn = bind(RunService.RenderStepped:Connect(function()
            pcall(renderPlayerESP)
            if ESP.enabled and ESP.method == "V2" and renderV2 then
                pcall(renderV2)
            end
            pcall(renderMobESP)
        end))
    elseif not wanted and espConn then
        unbind(espConn)
        espConn = nil
    end
end

bind(Players.PlayerRemoving:Connect(function(target)
    destroyDrawings(espObjects[target])
    espObjects[target] = nil
end))

yield(true)

---------------------------------------------------------------------
-- ESP V2 (BillboardGui)
--
-- The same information as V1, drawn as a real GUI adorned to the target's
-- torso instead of as a screen overlay: health and chakra as filled bars with
-- the numbers inside them, blood as a thin bar underneath, then distance,
-- status, combat timer and cooldowns.
--
-- Boxes, tracers, arrows and the highlight are NOT duplicated here - those
-- stay Drawing-based and are shared by both methods, so every toggle on the
-- ESP list keeps working whichever method is selected.
--
-- Font is the UI library's (Ubuntu) throughout, applied in one sweep at the
-- end so a label added later cannot quietly miss it.
---------------------------------------------------------------------
local V2_FONT     = Enum.Font.Ubuntu
local espV2       = {}   -- [Player] = BillboardGui
local espV2Adorn  = {}   -- [Player] = the torso it was built against

local function v2Torso(char)
    return char:FindFirstChild("UpperTorso")
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("HumanoidRootPart")
end

local function v2Label(parent, name, size, color)
    local label = Instance.new("TextLabel")
    label.Name                   = name
    label.Size                   = UDim2.new(1, 0, 0, size + 2)
    label.BackgroundTransparency = 1
    label.Font                   = V2_FONT
    label.TextSize               = size
    label.TextColor3             = color
    label.TextStrokeTransparency = 0
    label.TextStrokeColor3       = Color3.new(0, 0, 0)
    label.Text                   = ""
    label.Visible                = false
    label.Parent                 = parent
    return label
end

local function v2Bar(parent, width, height, x, y, fillColor, radius, withText)
    local bg = Instance.new("Frame")
    bg.Size             = UDim2.new(0, width, 0, height)
    bg.Position         = UDim2.new(0, x, 0, y)
    bg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    bg.BorderSizePixel  = 0
    bg.Parent           = parent

    local bgCorner = Instance.new("UICorner")
    bgCorner.CornerRadius = UDim.new(0, radius)
    bgCorner.Parent       = bg

    local fill = Instance.new("Frame")
    fill.Name             = "Fill"
    fill.Size             = UDim2.new(1, 0, 1, 0)
    fill.BackgroundColor3 = fillColor
    fill.BorderSizePixel  = 0
    fill.Parent           = bg

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, radius)
    fillCorner.Parent       = fill

    local text
    if withText then
        text = Instance.new("TextLabel")
        text.Name                   = "Value"
        text.Size                   = UDim2.new(1, 0, 1, 0)
        text.BackgroundTransparency = 1
        text.Font                   = V2_FONT
        text.TextSize               = 10
        text.TextColor3             = Color3.new(1, 1, 1)
        text.TextStrokeTransparency = 0
        text.TextStrokeColor3       = Color3.new(0, 0, 0)
        text.Text                   = ""
        text.ZIndex                 = 2
        text.Parent                 = bg
    end

    return { bg = bg, fill = fill, text = text }
end

local function createV2(target)
    local char  = target.Character
    local torso = char and v2Torso(char)
    if not torso then return nil end

    local size = ESP.textSize

    local billboard = Instance.new("BillboardGui")
    billboard.Name            = K.Services.HttpService:GenerateGUID(false)
    billboard.Adornee         = torso
    billboard.Size            = UDim2.new(0, 170, 0, 110)
    billboard.StudsOffset     = Vector3.new(0, 3.5, 0)
    billboard.AlwaysOnTop     = true
    billboard.LightInfluence  = 0
    billboard.MaxDistance     = ESP.maxDistance
    billboard.Parent          = hiddenParent()

    local main = Instance.new("Frame")
    main.Name                   = "Main"
    main.Size                   = UDim2.new(1, 0, 1, 0)
    main.BackgroundTransparency = 1
    main.Parent                 = billboard

    local parts = {
        gui      = billboard,
        main     = main,
        name     = v2Label(main, "Name",     size,     ESP.nameColor),
        info     = v2Label(main, "Info",     size - 2, ESP.distanceColor),
        status   = v2Label(main, "Status",   size - 3, ESP.awakenedColor),
        combat   = v2Label(main, "Combat",   size - 3, ESP.combatColor),
        cooldown = v2Label(main, "Cooldown", size - 3, ESP.cooldownColor),
    }

    -- Bars live in their own frame so the whole block can be hidden and the
    -- labels below it close the gap.
    local bars = Instance.new("Frame")
    bars.Name                   = "Bars"
    bars.Size                   = UDim2.new(0, 130, 0, 22)
    bars.Position               = UDim2.new(0.5, -65, 0, 0)
    bars.BackgroundTransparency = 1
    bars.Parent                 = main

    parts.bars   = bars
    parts.health = v2Bar(bars, 62, 14, 0,  0,  HP_HIGH,          4, true)
    parts.chakra = v2Bar(bars, 62, 14, 68, 0,  ESP.chakraColor,  4, true)
    parts.blood  = v2Bar(bars, 80, 4,  25, 17, ESP.bloodColor,   2, false)

    for _, d in ipairs(billboard:GetDescendants()) do
        if d:IsA("TextLabel") then
            pcall(function() d.Font = V2_FONT end)
        end
    end

    espV2[target]      = parts
    espV2Adorn[target] = torso
    return parts
end

local function destroyV2(target)
    local parts = espV2[target]
    if parts then
        pcall(function() parts.gui:Destroy() end)
        espV2[target] = nil
    end
    espV2Adorn[target] = nil
end

-- Assigned to the forward declaration above.
clearV2 = function()
    for target in pairs(espV2) do destroyV2(target) end
    espV2      = {}
    espV2Adorn = {}
end

-- Switching method leaves the other renderer's output on screen unless it is
-- explicitly put away, so both directions get a one-shot cleanup.
hideV1Labels = function()
    for _, data in pairs(espObjects) do
        for _, key in ipairs({ "NameTag", "DistanceTag", "HealthTag", "StatusTag", "CombatTag", "CooldownTag" }) do
            local obj = data[key]
            if obj then pcall(function() obj.Visible = false end) end
        end
        hideBar(data.HealthBg, data.HealthFill)
        hideBar(data.ChakraBg, data.ChakraFill)
        hideBar(data.BloodBg,  data.BloodFill)
    end
end

---------------------------------------------------------------------
-- V2 RENDER
---------------------------------------------------------------------
renderV2 = function()
    if not ESP.enabled or ESP.method ~= "V2" then return end

    local myRoot = root()
    local myPos  = myRoot and myRoot.Position
    local size   = ESP.textSize

    for _, target in ipairs(Players:GetPlayers()) do
        if target == LP then continue end

        local char = target.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")

        if not hum or not hrp or hum.Health <= 0 then
            destroyV2(target)
            continue
        end

        local distance = myPos and (hrp.Position - myPos).Magnitude or 0
        if distance > ESP.maxDistance then
            local parts = espV2[target]
            if parts then parts.gui.Enabled = false end
            continue
        end

        -- A respawn swaps the torso out from under the adornee.
        local torso = v2Torso(char)
        if espV2[target] and espV2Adorn[target] ~= torso then
            destroyV2(target)
        end

        local parts = espV2[target] or createV2(target)
        if not parts then continue end

        parts.gui.Enabled     = true
        parts.gui.MaxDistance = ESP.maxDistance

        local team      = isTeammate(target)
        local nameColor = team and ESP.teamColor or ESP.nameColor
        local y         = 0

        -- Name (+ clan inline, as in V1)
        if ESP.showName then
            local label = target.Name
            if ESP.showClan then
                local clan = bloodlineOf(target)
                if clan then label = label .. " [" .. clan .. "]" end
            end
            parts.name.Visible    = true
            parts.name.Text       = label
            parts.name.TextColor3 = nameColor
            parts.name.TextSize   = size
            parts.name.Position   = UDim2.new(0, 0, 0, y)
            parts.name.Size       = UDim2.new(1, 0, 0, size + 2)
            y = y + size + 2
        else
            parts.name.Visible = false
        end

        -- Bars
        local hpPct  = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
        local ckPct, ckCur, ckMax = chakraPct(target)
        local bdPct  = bloodPct(target)

        local showHp = ESP.showHealthBar
        local showCk = ESP.showChakraBar and ckPct ~= nil
        local showBd = ESP.showBloodBar and bdPct ~= nil
        local anyBar = showHp or showCk or showBd

        parts.bars.Visible = anyBar
        if anyBar then
            parts.bars.Position = UDim2.new(0.5, -65, 0, y)

            parts.health.bg.Visible = showHp
            if showHp then
                parts.health.fill.Size            = UDim2.new(hpPct, 0, 1, 0)
                parts.health.fill.BackgroundColor3 = healthColor(hpPct)
                parts.health.text.Text            = string.format("%d/%d", math.floor(hum.Health), math.floor(hum.MaxHealth))
            end

            parts.chakra.bg.Visible = showCk
            if showCk then
                parts.chakra.fill.Size             = UDim2.new(ckPct, 0, 1, 0)
                parts.chakra.fill.BackgroundColor3 = ESP.chakraColor
                parts.chakra.text.Text             = string.format("%d/%d", ckCur or 0, ckMax or 100)
            end

            parts.blood.bg.Visible = showBd
            if showBd then
                parts.blood.fill.Size             = UDim2.new(bdPct, 0, 1, 0)
                parts.blood.fill.BackgroundColor3 = ESP.bloodColor
            end

            -- A single row of bars is 14 tall; blood adds its own strip.
            local barsHeight = 0
            if showHp or showCk then barsHeight = 14 end
            if showBd then barsHeight = barsHeight + 8 end
            parts.bars.Size = UDim2.new(0, 130, 0, barsHeight)
            y = y + barsHeight + 2
        end

        -- Info row: distance, plus the HP number when the bar that normally
        -- carries it is switched off.
        local info = {}
        if ESP.showDistance then
            info[#info + 1] = string.format("%d studs", math.floor(distance))
        end
        if ESP.showHealthText and not showHp then
            info[#info + 1] = string.format("%d/%d HP", math.floor(hum.Health), math.floor(hum.MaxHealth))
        end

        if #info > 0 then
            parts.info.Visible    = true
            parts.info.Text       = table.concat(info, "  |  ")
            parts.info.TextColor3 = ESP.distanceColor
            parts.info.TextSize   = size - 2
            parts.info.Position   = UDim2.new(0, 0, 0, y)
            y = y + size
        else
            parts.info.Visible = false
        end

        -- Status: skill, else awakened mode, else freshie - same precedence
        -- the V1 renderer uses.
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

        if status then
            parts.status.Visible    = true
            parts.status.Text       = status
            parts.status.TextColor3 = statusColor
            parts.status.TextSize   = size - 3
            parts.status.Position   = UDim2.new(0, 0, 0, y)
            y = y + size - 1
        else
            parts.status.Visible = false
        end

        if ESP.showCombatTimer then
            local timer = combatTimerOf(target)
            if timer and timer > 0 then
                parts.combat.Visible    = true
                parts.combat.Text       = string.format("Combat %ds", math.floor(timer))
                parts.combat.TextColor3 = ESP.combatColor
                parts.combat.TextSize   = size - 3
                parts.combat.Position   = UDim2.new(0, 0, 0, y)
                y = y + size - 1
            else
                parts.combat.Visible = false
            end
        else
            parts.combat.Visible = false
        end

        if ESP.showCooldowns then
            local list = cooldownsOf(target, ESP.maxCooldowns)
            if list then
                parts.cooldown.Visible    = true
                parts.cooldown.Text       = list
                parts.cooldown.TextColor3 = ESP.cooldownColor
                parts.cooldown.TextSize   = size - 3
                parts.cooldown.Position   = UDim2.new(0, 0, 0, y)
                y = y + size - 1
            else
                parts.cooldown.Visible = false
            end
        else
            parts.cooldown.Visible = false
        end

        -- Grow the billboard to whatever the stack actually needs, and keep
        -- the block sitting above the head rather than drifting down it.
        parts.gui.Size        = UDim2.new(0, 170, 0, math.max(y, 20))
        parts.gui.StudsOffset = Vector3.new(0, 3.5, 0)
    end

    -- Anyone who left keeps their billboard otherwise.
    for target in pairs(espV2) do
        if target.Parent ~= Players then destroyV2(target) end
    end
end

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

-- V1 draws the whole readout as a screen overlay; V2 adorns a BillboardGui to
-- the target instead. Boxes, tracers, arrows and the highlight are shared, so
-- every other toggle below applies to both.
UI.boxPlayerESP.element("Dropdown", "ESP Method", {
    options = { "V1", "V2" },
    default = { Dropdown = "V1" },
}, function(v)
    if v.Dropdown == ESP.method then return end
    ESP.method = v.Dropdown

    -- Put the other renderer's output away, or it stays frozen on screen.
    if ESP.method == "V2" then
        if hideV1Labels then hideV1Labels() end
    else
        if clearV2 then clearV2() end
    end

    notify("Visuals", "ESP method: " .. ESP.method, 2)
end)

UI.boxPlayerESP.element("Toggle", "Enable Player ESP", nil, function(v)
    -- V2's text is a real GUI; only the shared box/tracer layer needs Drawing.
    if v.Toggle and ESP.method == "V1" and not drawingAvailable() then return end

    ESP.enabled = v.Toggle
    if not v.Toggle then
        clearPlayerESP()
        if clearV2 then clearV2() end
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

UI.boxPlayerESP.element("Toggle", "Off-Screen Arrows", nil, function(v)
    ESP.showArrows = v.Toggle
end):add_color({ Color = ESP.arrowColor }, false, function(c)
    ESP.arrowColor = c.Color
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

UI.boxPlayerESPOpt.element("Slider", "Arrow Distance", {
    default = { min = 50, max = 400, default = 150 },
}, function(v)
    ESP.arrowOffset = v.Slider
end)

UI.boxPlayerESPOpt.element("Slider", "Arrow Size", {
    default = { min = 5, max = 30, default = 15 },
}, function(v)
    ESP.arrowSize = v.Slider
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

    hrp.CFrame = targetCFrame
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

-- opts = { width, height, y, list }
local function makePanel(opts)
    local panel = { draggable = false, rows = 0 }

    panel.frame = Instance.new("Frame")
    panel.frame.Size             = UDim2.new(0, opts.width, 0, opts.height)
    panel.frame.Position         = UDim2.new(0.5, -opts.width / 2, 0, opts.y)
    panel.frame.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
    panel.frame.BorderSizePixel  = 0
    panel.frame.Visible          = false
    panel.frame.ZIndex           = 2
    panel.frame.Parent           = hudRoot()

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent       = panel.frame

    local stroke = Instance.new("UIStroke")
    stroke.Color     = Color3.fromRGB(152, 84, 255)
    stroke.Thickness = 2
    stroke.Parent    = panel.frame

    panel.left = Instance.new("TextLabel")
    panel.left.BackgroundTransparency = 1
    panel.left.Position       = UDim2.new(0, 12, 0, 0)
    panel.left.Size           = UDim2.new(0.6, -16, 1, 0)
    panel.left.Font           = Enum.Font.GothamBold
    panel.left.TextSize       = 15
    panel.left.TextColor3     = Color3.fromRGB(255, 255, 255)
    panel.left.TextXAlignment = Enum.TextXAlignment.Left
    panel.left.TextTruncate   = Enum.TextTruncate.AtEnd
    panel.left.Text           = ""
    panel.left.ZIndex         = 3
    panel.left.Parent         = panel.frame

    panel.right = Instance.new("TextLabel")
    panel.right.BackgroundTransparency = 1
    panel.right.Position       = UDim2.new(0.6, 0, 0, 0)
    panel.right.Size           = UDim2.new(0.4, -12, 1, 0)
    panel.right.Font           = Enum.Font.GothamBold
    panel.right.TextSize       = 14
    panel.right.TextColor3     = Color3.fromRGB(34, 197, 94)
    panel.right.TextXAlignment = Enum.TextXAlignment.Right
    panel.right.Text           = ""
    panel.right.ZIndex         = 3
    panel.right.Parent         = panel.frame

    -- Optional hover list (chakra sense uses it for the names).
    if opts.list then
        panel.list = Instance.new("Frame")
        panel.list.Size             = UDim2.new(0, 220, 0, 0)
        panel.list.Position         = UDim2.new(0, 0, 1, 6)
        panel.list.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
        panel.list.BorderSizePixel  = 0
        panel.list.Visible          = false
        panel.list.ClipsDescendants = true
        panel.list.ZIndex           = 6
        panel.list.Parent           = panel.frame

        local listCorner = Instance.new("UICorner")
        listCorner.CornerRadius = UDim.new(0, 8)
        listCorner.Parent       = panel.list

        local listStroke = Instance.new("UIStroke")
        listStroke.Color     = Color3.fromRGB(152, 84, 255)
        listStroke.Thickness = 1
        listStroke.Parent    = panel.list

        local layout = Instance.new("UIListLayout")
        layout.FillDirection = Enum.FillDirection.Vertical
        layout.SortOrder     = Enum.SortOrder.Name
        layout.Padding       = UDim.new(0, 2)
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

        -- Replace the whole list. Entry count drives the height, so a panel
        -- with nothing in it never opens an empty box.
        function panel.set_list(entries)
            -- Rebuilding eight TextLabels ten times a second for a list that
            -- has not changed is pure churn; key off the contents instead.
            local key = table.concat(entries, "")
            if key == panel._key then return end
            panel._key = key

            for _, child in ipairs(panel.list:GetChildren()) do
                if child:IsA("TextLabel") then child:Destroy() end
            end

            for _, entry in ipairs(entries) do
                local row = Instance.new("TextLabel")
                row.BackgroundTransparency = 1
                row.Size           = UDim2.new(1, 0, 0, 16)
                row.Font           = Enum.Font.Gotham
                row.TextSize       = 13
                row.TextColor3     = Color3.fromRGB(230, 230, 230)
                row.TextXAlignment = Enum.TextXAlignment.Left
                row.Text           = entry
                row.Name           = entry
                row.ZIndex         = 7
                row.Parent         = panel.list
            end

            panel.rows      = #entries
            panel.list.Size = UDim2.new(0, 220, 0, math.min(#entries, 8) * 18 + 10)
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

yield()

---------------------------------------------------------------------
-- MISC :: VIEW DATA
--
-- GetData is a RemoteFunction, so this is one round trip on demand, not a
-- poll. Table values are flattened to a single line so a stat with sub-keys
-- (UsedSkills, quest tables) still fits a notification.
---------------------------------------------------------------------
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

yield(true)

---------------------------------------------------------------------
-- SECURITY :: SAFE TELEPORT UI
---------------------------------------------------------------------
UI.boxSafeTp.element("Toggle", "Safe Teleport", ON, function(v)
    Safe.enabled = v.Toggle
    notify("Security", "Safe Teleport " .. (v.Toggle and "enabled" or "disabled"))
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
-- The readout: a count on the left, a state on the right, and the names
-- themselves on hover. Green = nobody, orange = somebody has it equipped,
-- red = somebody is actively sensing right now.
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

    panel.left.Text = "Chakra Sense Users: " .. #names

    if next(Sense.observing) then
        panel.right.Text       = "Spectators = Active"
        panel.right.TextColor3 = Color3.fromRGB(239, 68, 68)
    elseif next(Sense.hovering) then
        panel.right.Text       = "Spectators = Equipped"
        panel.right.TextColor3 = Color3.fromRGB(255, 165, 0)
    else
        panel.right.Text       = "Spectators = None"
        panel.right.TextColor3 = Color3.fromRGB(34, 197, 94)
    end

    local rows = {}
    for _, name in ipairs(names) do
        if Sense.observing[name] then
            rows[#rows + 1] = name .. "  (sensing)"
        elseif Sense.hovering[name] then
            rows[#rows + 1] = name .. "  (equipped)"
        else
            rows[#rows + 1] = name
        end
    end
    panel.set_list(rows)
end

local function senseEvaluate()
    if not Sense.enabled then return end

    local cooldowns = RepStorage:FindFirstChild("Cooldowns")
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
                        playSenseSound("124951621656853")
                    end
                elseif Sense.observing[name] then
                    Sense.observing[name] = nil
                    notify("Chakra Sense", name .. " stopped observing you")
                    playSenseSound("8551372796")
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
        Sense.panel = makePanel({ width = 400, height = 46, y = 20, list = true })
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

    local cooldowns = RepStorage:FindFirstChild("Cooldowns")
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
-- READ-ONLY EXTRAS
--
-- Everything in this block is passive: it reads replicated state or moves the
-- local camera. Nothing here fires a remote, writes to a replicated value or
-- touches the character, so none of it can be seen server side.
---------------------------------------------------------------------
local RO = {}

---------------------------------------------------------------------
-- ITEM ESP
--
-- A dropped item is a direct child of workspace carrying an "ID" child -
-- that one test is what separates loot from scenery, and it is what the game
-- itself uses. The nearest-player readout answers the only question that
-- actually matters about a drop: can you get there before they do.
---------------------------------------------------------------------
RO.item = {
    enabled       = false,
    showName      = true,
    showDistance  = true,
    showNearest   = true,
    maxDistance   = 500,
    textSize      = 14,
    nameColor     = Color3.fromRGB(255, 220, 120),
    distanceColor = Color3.fromRGB(200, 200, 200),
    nearestColor  = Color3.fromRGB(255, 120, 120),
    objects       = {},
    conn          = nil,
    scan          = 0,
    list          = {},
}

local function itemDrawings(item)
    if RO.item.objects[item] then return end
    RO.item.objects[item] = {
        NameTag     = textDrawing(14),
        DistanceTag = textDrawing(12),
        NearestTag  = textDrawing(12),
    }
end

local function clearItemESP()
    for _, data in pairs(RO.item.objects) do destroyDrawings(data) end
    RO.item.objects = {}
    RO.item.list    = {}
end

local function itemPart(item)
    if item:IsA("BasePart") then return item end
    return item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
end

local function renderItemESP()
    if not RO.item.enabled then return end

    local cam = workspace.CurrentCamera
    local myRoot = root()
    if not cam or not myRoot then return end

    -- Rescanning workspace every frame is the expensive part, so the item
    -- list is rebuilt twice a second and only the drawing work is per-frame.
    local now = os.clock()
    if now - RO.item.scan > 0.5 then
        RO.item.scan = now
        local found = {}
        for _, child in ipairs(workspace:GetChildren()) do
            if (child:IsA("BasePart") or child:IsA("Model")) and child:FindFirstChild("ID") then
                found[#found + 1] = child
            end
        end
        RO.item.list = found

        for item, data in pairs(RO.item.objects) do
            if not item.Parent then
                destroyDrawings(data)
                RO.item.objects[item] = nil
            end
        end
    end

    local W2VP = cam.WorldToViewportPoint

    for _, item in ipairs(RO.item.list) do
        local part = itemPart(item)
        local data = RO.item.objects[item]

        if not part then
            hideDrawings(data)
            continue
        end

        local distance = (part.Position - myRoot.Position).Magnitude
        if distance > RO.item.maxDistance then
            hideDrawings(data)
            continue
        end

        local screen, onScreen = W2VP(cam, part.Position + Vector3.new(0, 1.5, 0))
        if not onScreen then
            hideDrawings(data)
            continue
        end

        if not data then
            itemDrawings(item)
            data = RO.item.objects[item]
            if not data then continue end
        end

        local y = screen.Y

        if RO.item.showName then
            data.NameTag.Visible  = true
            data.NameTag.Position = Vector2.new(screen.X, y)
            data.NameTag.Text     = item.Name
            data.NameTag.Color    = RO.item.nameColor
            data.NameTag.Size     = RO.item.textSize
            y = y + RO.item.textSize
        else
            data.NameTag.Visible = false
        end

        if RO.item.showDistance then
            data.DistanceTag.Visible  = true
            data.DistanceTag.Position = Vector2.new(screen.X, y)
            data.DistanceTag.Text     = string.format("%d studs", math.floor(distance))
            data.DistanceTag.Color    = RO.item.distanceColor
            data.DistanceTag.Size     = RO.item.textSize - 2
            y = y + RO.item.textSize - 1
        else
            data.DistanceTag.Visible = false
        end

        if RO.item.showNearest then
            local best, bestDist = nil, math.huge
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LP then
                    local char = p.Character
                    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local d = (hrp.Position - part.Position).Magnitude
                        if d < bestDist then best, bestDist = p, d end
                    end
                end
            end

            if best then
                data.NearestTag.Visible  = true
                data.NearestTag.Position = Vector2.new(screen.X, y)
                data.NearestTag.Text     = string.format("%s (%d)", best.Name, math.floor(bestDist))
                data.NearestTag.Color    = RO.item.nearestColor
                data.NearestTag.Size     = RO.item.textSize - 2
            else
                data.NearestTag.Visible = false
            end
        else
            data.NearestTag.Visible = false
        end
    end
end

UI.itemESP.element("Toggle", "Enable Item ESP", nil, function(v)
    if v.Toggle and not drawingAvailable() then return end
    RO.item.enabled = v.Toggle

    if v.Toggle then
        RO.item.scan = 0
        if not RO.item.conn then
            RO.item.conn = bind(RunService.RenderStepped:Connect(function()
                pcall(renderItemESP)
            end))
        end
    else
        if RO.item.conn then
            unbind(RO.item.conn)
            RO.item.conn = nil
        end
        clearItemESP()
    end

    notify("Visuals", "Item ESP " .. (v.Toggle and "enabled" or "disabled"))
end)

UI.itemESP.create_line()

UI.itemESP.element("Toggle", "Show Item Name", { default = { Toggle = true } }, function(v)
    RO.item.showName = v.Toggle
end):add_color({ Color = RO.item.nameColor }, false, function(c)
    RO.item.nameColor = c.Color
end)

UI.itemESP.element("Toggle", "Show Item Distance", { default = { Toggle = true } }, function(v)
    RO.item.showDistance = v.Toggle
end)

UI.itemESP.element("Toggle", "Show Nearest Player", { default = { Toggle = true } }, function(v)
    RO.item.showNearest = v.Toggle
end):add_color({ Color = RO.item.nearestColor }, false, function(c)
    RO.item.nearestColor = c.Color
end)

UI.itemESP.element("Slider", "Item Max Distance", {
    default = { min = 50, max = 2000, default = 500 },
    suffix  = " studs",
}, function(v)
    RO.item.maxDistance = v.Slider
end)

UI.itemESP.element("Slider", "Item Text Size", {
    default = { min = 10, max = 24, default = 14 },
}, function(v)
    RO.item.textSize = v.Slider
end)

yield()

---------------------------------------------------------------------
-- FIELD OF VIEW
--
-- Bound at RenderPriority.Last so our write lands AFTER the game's camera
-- module (priority Camera = 200). A plain RenderStepped connection runs
-- before it, and the game overwrites the value every frame.
---------------------------------------------------------------------
RO.fov = { enabled = false, value = 70, bound = false, key = "kyo_fov_" .. tostring(math.random(1000, 9999)) }

UI.camera.element("Toggle", "Custom FOV", nil, function(v)
    RO.fov.enabled = v.Toggle

    if v.Toggle then
        if not RO.fov.bound then
            RO.fov.bound = true
            RunService:BindToRenderStep(RO.fov.key, Enum.RenderPriority.Last.Value, function()
                local cam = workspace.CurrentCamera
                if cam and cam.FieldOfView ~= RO.fov.value then
                    cam.FieldOfView = RO.fov.value
                end
            end)
        end
    else
        if RO.fov.bound then
            RO.fov.bound = false
            pcall(function() RunService:UnbindFromRenderStep(RO.fov.key) end)
        end
        pcall(function() workspace.CurrentCamera.FieldOfView = 70 end)
    end
end)

UI.camera.element("Slider", "FOV", {
    default = { min = 40, max = 160, default = 70 },
}, function(v)
    RO.fov.value = v.Slider
end)

UI.camera.create_line()

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
    key     = "kyo_stretch_" .. tostring(math.random(1000, 9999)),
    last    = nil,
}

local function stretchStep()
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
end

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
UI.server.element("Button", "Copy Job ID", nil, function()
    if not setclipboard then
        notify("Server", game.JobId, 8)
        return
    end
    pcall(setclipboard, game.JobId)
    notify("Server", "Job ID copied")
end)

UI.server.element("Button", "Copy Join Command", nil, function()
    local cmd = string.format(
        'game:GetService("TeleportService"):TeleportToPlaceInstance(%d, "%s", game:GetService("Players").LocalPlayer)',
        game.PlaceId, game.JobId
    )
    if not setclipboard then
        notify("Server", "Clipboard unavailable", 4)
        return
    end
    pcall(setclipboard, cmd)
    notify("Server", "Join command copied")
end)

UI.server.element("Button", "Server Info", nil, function()
    local ping = "?"
    pcall(function()
        local stat = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]
        ping = string.format("%.0f ms", stat:GetValue())
    end)

    notify("Server", string.format("%d/%d players  |  up %d min  |  %s",
        #Players:GetPlayers(),
        Players.MaxPlayers,
        math.floor(workspace.DistributedGameTime / 60),
        ping), 8)
end)

yield()

---------------------------------------------------------------------
-- WATCHERS
---------------------------------------------------------------------
RO.watch = { events = false, eventConn = nil, joins = false, joinConns = {} }

UI.watchers.element("Toggle", "Event Notifier", nil, function(v)
    RO.watch.events = v.Toggle

    if v.Toggle then
        RO.watch.eventConn = bind(workspace.ChildAdded:Connect(function(obj)
            if not RO.watch.events then return end

            if obj.Name == "CorruptedPoint" or obj.Name == "PresentPoint" then
                notify("Event", obj.Name .. " spawned", 8)
                return
            end

            -- World event NPCs stream their children in, so the tag is not
            -- there on the frame the model arrives.
            task.delay(1, function()
                if not RO.watch.events or not obj.Parent then return end
                if obj:FindFirstChild("WorldEvent") then
                    notify("Event", "World event started: " .. obj.Name, 8)

                    local hl = Instance.new("Highlight")
                    hl.Name                = "kyo_event_marker"
                    hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.FillColor           = Color3.fromRGB(224, 57, 99)
                    hl.OutlineColor        = Color3.fromRGB(224, 57, 99)
                    hl.FillTransparency    = 0.7
                    hl.Adornee             = obj
                    pcall(function() hl.Parent = hiddenParent() end)
                    K.Services.Debris:AddItem(hl, 120)
                end
            end)
        end))
        notify("Misc", "Event Notifier enabled")
    else
        if RO.watch.eventConn then
            unbind(RO.watch.eventConn)
            RO.watch.eventConn = nil
        end
        notify("Misc", "Event Notifier disabled")
    end
end)

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
    ignoreUsers   = "",
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

    if Prox.ignoreUsers ~= "" then
        local lower = string.lower(target.Name)
        for entry in string.gmatch(Prox.ignoreUsers, "[^,]+") do
            if string.lower((entry:gsub("^%s*(.-)%s*$", "%1"))) == lower then
                return true
            end
        end
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
            Prox.panel = makePanel({ width = 340, height = 38, y = 76, list = true })
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
                    Prox.panel.left.Text        = "Nearest: none"
                    Prox.panel.right.Text       = ""
                else
                    local first = near[1]
                    Prox.panel.left.Text  = string.format("Nearest: %s", first.player.Name)
                    Prox.panel.right.Text = string.format("%d studs", math.floor(first.distance))
                    Prox.panel.right.TextColor3 =
                        (Prox.warnRange > 0 and first.distance <= Prox.warnRange)
                        and Color3.fromRGB(239, 68, 68)
                        or Color3.fromRGB(34, 197, 94)

                    for i = 1, math.min(#near, 8) do
                        rows[i] = string.format("%s  -  %d", near[i].player.Name, math.floor(near[i].distance))
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

UI.boxDetection.element("TextBox", "Ignore Users (comma sep)", { maxlen = 120 }, function(v)
    Prox.ignoreUsers = v.Text
end)

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
UI.boxMenu.element("Label", "Kyo - Private")
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
    pcall(senseStop)
    pcall(stopMobRegistry)
    pcall(restoreVisuals)

    pcall(clearPlayerESP)
    pcall(clearMobESP)
    if clearV2 then pcall(clearV2) end

    -- Read-only extras: camera bindings and lighting overrides have to be
    -- handed back explicitly, they are not connections.
    RO.item.enabled     = false
    RO.freecam.enabled  = false
    RO.stretch.enabled  = false
    RO.watch.events     = false
    RO.watch.joins      = false
    RO.world.fullbright = false
    RO.world.nofog      = false

    pcall(clearItemESP)
    pcall(freecamStop)
    pcall(stretchStop)
    pcall(restoreWorld)

    if RO.fov.bound then
        RO.fov.bound = false
        pcall(function() RunService:UnbindFromRenderStep(RO.fov.key) end)
    end
    pcall(function() workspace.CurrentCamera.FieldOfView = 70 end)

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
        getgenv().__kyo_priv = nil
        getgenv()[_genvKey]  = nil
    end)
end

UI.boxMenu.element("Button", "Unload Script", nil, function()
    notify("Kyo", "Unloading...", 2)
    task.delay(0.35, unload)
end)

---------------------------------------------------------------------
-- FINALISE
---------------------------------------------------------------------
pcall(function()
    -- One small marker, under a per-run random key, plus the unload handle so
    -- a re-execute can retire this instance instead of stacking on top of it.
    getgenv()[_genvKey]  = os.clock()
    getgenv().__kyo_priv = unload
end)

yield(true)

notify("Kyo - Private", "Loaded. Press Insert to toggle.", 5)
