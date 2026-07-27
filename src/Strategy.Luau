repeat
	task.wait()
until game:IsLoaded() and game.PlaceId ~= 0

local clone = cloneref or function(value)
	return value
end

local Players = clone(game:GetService("Players"))
local ReplicatedStorage = clone(game:GetService("ReplicatedStorage"))
local RunService = clone(game:GetService("RunService"))
local Workspace = clone(game:GetService("Workspace"))

local lp = clone(Players.LocalPlayer)
local shared = ReplicatedStorage:WaitForChild("Shared")
local modules = shared:WaitForChild("Modules")
local gameState = require(modules:WaitForChild("GameState"))
local net = require(modules:WaitForChild("Network"))
local lobbyId = 3260590327
local repoRoot = getgenv().AutoStratRoot or "https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/"

local Strategy = {}
Strategy.__index = Strategy

local function quote(value)
	return string.format("%q", tostring(value or ""))
end

local function number(value)
	if value ~= value then
		return "0/0"
	elseif value == math.huge then
		return "math.huge"
	elseif value == -math.huge then
		return "-math.huge"
	end
	return string.format("%.17g", value)
end

local function isArray(value)
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count = math.max(count, key)
	end
	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end
	return true, count
end

local function teleportQueue()
	if type(queue_on_teleport) == "function" then
		return queue_on_teleport
	elseif type(queueonteleport) == "function" then
		return queueonteleport
	elseif type(syn) == "table" and type(syn.queue_on_teleport) == "function" then
		return syn.queue_on_teleport
	elseif type(fluxus) == "table" and type(fluxus.queue_on_teleport) == "function" then
		return fluxus.queue_on_teleport
	end
end

local function timerValue()
	local state = ReplicatedStorage:FindFirstChild("State")
	local timer = state and state:FindFirstChild("Timer")
	return timer and timer:FindFirstChild("Time")
end

local function split(value)
	local out = {}
	for part in tostring(value):gmatch("[^%.]+") do
		out[#out + 1] = part
	end
	return out
end

function Strategy.new()
	return setmetatable({
		actions = {},
		loadout = {},
		meta = {},
		name = "Strategy",
		nextTower = 0,
		running = false,
		seq = 0,
		status = "Idle",
		towers = {},
	}, Strategy)
end

function Strategy:Name(value)
	self.name = tostring(value or "Strategy")
	return self
end

function Strategy:Loadout(...)
	self.loadout = { ... }
	return self
end

function Strategy:Map(name, override, mode, difficulty)
	self.meta = {
		Map = name,
		Override = override == true,
		Mode = mode,
		Difficulty = difficulty,
	}
	return self
end

function Strategy:Tower(id)
	return { __kind = "tower", id = id }
end

function Strategy:Find(path)
	return { __kind = "instance", path = path }
end

function Strategy:Enum(path)
	return { __kind = "enum", path = path }
end

function Strategy:Import(data)
	if type(data) ~= "table" then
		return self
	end
	self.actions = data.actions or {}
	self.loadout = data.loadout or {}
	self.meta = data.meta or {}
	self.name = tostring(data.name or "Strategy")
	self.nextTower = tonumber(data.nextTower) or 0
	self.towers = {}
	return self
end

function Strategy:_literal(value, seen)
	local kind = typeof(value)
	if kind == "nil" then
		return "nil"
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		return number(value)
	elseif kind == "string" then
		return quote(value)
	elseif kind == "Vector2" then
		return string.format("Vector2.new(%s, %s)", number(value.X), number(value.Y))
	elseif kind == "Vector3" then
		return string.format("Vector3.new(%s, %s, %s)", number(value.X), number(value.Y), number(value.Z))
	elseif kind == "Color3" then
		return string.format("Color3.new(%s, %s, %s)", number(value.R), number(value.G), number(value.B))
	elseif kind == "CFrame" then
		local values = { value:GetComponents() }
		for index, item in ipairs(values) do
			values[index] = number(item)
		end
		return "CFrame.new(" .. table.concat(values, ", ") .. ")"
	elseif kind ~= "table" then
		return quote(tostring(value))
	end

	seen = seen or {}
	if seen[value] then
		return "nil"
	end
	seen[value] = true
	local array, count = isArray(value)
	local parts = {}
	if array then
		for index = 1, count do
			parts[index] = self:_literal(value[index], seen)
		end
	else
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			local left
			if type(key) == "string" and key:match("^[%a_][%w_]*$") then
				left = key
			else
				left = "[" .. self:_literal(key, seen) .. "]"
			end
			parts[#parts + 1] = left .. " = " .. self:_literal(value[key], seen)
		end
	end
	seen[value] = nil
	return "{ " .. table.concat(parts, ", ") .. " }"
end

function Strategy:_resume()
	local data = {
		actions = self.actions,
		loadout = self.loadout,
		meta = self.meta,
		name = self.name,
		nextTower = self.nextTower,
	}
	local url = repoRoot .. "src/Strategy.Luau"
	return table.concat({
		"repeat task.wait() until game:IsLoaded() and game.PlaceId ~= 0",
		"getgenv().AutoStratRoot = " .. quote(repoRoot),
		"local TDS = loadstring(game:HttpGet(" .. quote(url) .. ", true))()",
		"getgenv().AutoStratRoot = nil",
		"TDS:Import(" .. self:_literal(data) .. ")",
		"TDS:Run()",
	}, "\n")
end

function Strategy:_queue()
	local queue = teleportQueue()
	if not queue then
		return false, "This executor does not support queue_on_teleport."
	end
	local ok, err = pcall(queue, self:_resume())
	if not ok then
		return false, "Could not queue the strategy: " .. tostring(err)
	end
	return true
end

function Strategy:_add(kind, value, wave, minute, second, millisecond)
	value.kind = kind
	value.wave = math.max(math.floor(tonumber(wave) or 0), 0)
	value.time = math.max(
		(math.floor(tonumber(minute) or 0) * 60)
			+ math.floor(tonumber(second) or 0)
			+ (math.floor(tonumber(millisecond) or 0) / 1000),
		0
	)
	value.seq = #self.actions + 1
	self.actions[value.seq] = value
	return self
end

function Strategy:Place(name, x, y, z, wave, minute, second, millisecond, rotation, golden)
	self.nextTower = self.nextTower + 1
	return self:_add("place", {
		name = name,
		position = Vector3.new(x, y, z),
		rotation = rotation or CFrame.new(),
		golden = golden == true,
		id = self.nextTower,
	}, wave, minute, second, millisecond)
end

function Strategy:Upgrade(id, wave, minute, second, millisecond, path)
	return self:_add("upgrade", {
		id = id,
		path = tonumber(path) or 0,
	}, wave, minute, second, millisecond)
end

function Strategy:Sell(id, wave, minute, second, millisecond)
	return self:_add("sell", { id = id }, wave, minute, second, millisecond)
end

function Strategy:Ability(id, name, wave, minute, second, millisecond, data)
	return self:_add("ability", {
		id = id,
		name = name,
		data = data or {},
	}, wave, minute, second, millisecond)
end

function Strategy:Skip(wave, minute, second, millisecond)
	return self:_add("skip", {}, wave, minute, second, millisecond)
end

function Strategy:Target(id, target, wave, minute, second, millisecond)
	return self:_add("target", {
		id = id,
		target = target,
	}, wave, minute, second, millisecond)
end

function Strategy:Option(id, name, value, wave, minute, second, millisecond)
	return self:_add("option", {
		id = id,
		name = name,
		value = value,
	}, wave, minute, second, millisecond)
end

function Strategy:Raw(channel, action, args, wave, minute, second, millisecond, invoke)
	return self:_add("raw", {
		channel = channel,
		action = action,
		args = args,
		invoke = invoke == true,
	}, wave, minute, second, millisecond)
end

function Strategy:_find(path)
	local parts = split(path)
	local root = table.remove(parts, 1)
	local ok, value = pcall(game.GetService, game, root)
	if not ok then
		value = game:FindFirstChild(root)
	end
	for _, part in ipairs(parts) do
		value = value and value:FindFirstChild(part)
	end
	return value
end

function Strategy:_enum(path)
	local parts = split(path)
	if parts[1] ~= "Enum" then
		return nil
	end
	local family = Enum[parts[2]]
	return family and family[parts[3]]
end

function Strategy:_resolve(value, seen)
	if type(value) ~= "table" then
		return value
	elseif value.__kind == "tower" then
		return self.towers[value.id]
	elseif value.__kind == "instance" then
		return self:_find(value.path)
	elseif value.__kind == "enum" then
		return self:_enum(value.path)
	end

	seen = seen or {}
	if seen[value] then
		return nil
	end
	seen[value] = true
	local out = {}
	for key, item in pairs(value) do
		out[self:_resolve(key, seen)] = self:_resolve(item, seen)
	end
	seen[value] = nil
	return out
end

function Strategy:_mode()
	local mode = tostring(self.meta.Mode or ""):lower():gsub("%s+", "")
	local modes = {
		hardcore = "hardcore",
		pvp = "pvp",
		sandbox = "sandbox",
		survival = "survival",
	}
	return modes[mode]
end

function Strategy:_matchmake()
	local mode = self:_mode()
	if not mode then
		return false, "Unsupported gamemode: " .. tostring(self.meta.Mode)
	end
	local queued, queueErr = self:_queue()
	if not queued then
		return false, queueErr
	end

	local ok, uiNet = pcall(require, shared:WaitForChild("UI"):WaitForChild("Network"))
	if not ok then
		return false, "Could not load lobby matchmaking: " .. tostring(uiNet)
	end
	local opts = {
		count = 1,
		mode = mode,
	}
	if mode ~= "sandbox" and self.meta.Difficulty and self.meta.Difficulty ~= "" then
		opts.difficulty = self.meta.Difficulty
	end

	self.status = "Starting solo " .. tostring(self.meta.Mode)
	local channel = uiNet.Channel("Multiplayer")
	local called, success, msg = pcall(channel.InvokeServer, channel, "v2:start", opts)
	if not called then
		return false, "Matchmaking failed: " .. tostring(success)
	elseif success ~= true then
		return false, tostring(msg or success)
	end
	self.status = "Matchmaking..."
	return true
end

function Strategy:_selectMap()
	local wanted = tostring(self.meta.Map or "")
	local voting = net.Channel("LobbyVoting")
	local selected = wanted == "" or tostring(gameState.MapName or "") == wanted

	if not selected and self.meta.Override then
		local ok, success = pcall(voting.InvokeServer, voting, "Override", wanted)
		selected = ok and success == true
	end

	if not selected then
		for index = 1, 4 do
			if Workspace:GetAttribute("Map" .. index) == wanted then
				local char = lp.Character
				local pos = char and char:GetPivot().Position or Vector3.zero
				voting:FireServer("Vote", wanted, pos)
				selected = true
				break
			end
		end
	end

	if not selected then
		return false, "Map unavailable: " .. wanted
	end

	voting:FireServer("Ready")
	self.status = "Waiting for " .. (wanted ~= "" and wanted or "the match")
	return true
end

function Strategy:_prepare(seq)
	if gameState.GameStarted then
		return true
	end
	if self:_mode() == "sandbox" then
		self.status = "Waiting for Sandbox"
		while self.running and self.seq == seq do
			if gameState.GameStarted then
				return true
			end
			RunService.Heartbeat:Wait()
		end
		return false, "Stopped"
	end
	task.wait(1)
	if gameState.GameStarted then
		return true
	end
	local selected, err = self:_selectMap()
	if not selected then
		return false, err
	end
	while self.running and self.seq == seq do
		if gameState.GameStarted then
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false, "Stopped"
end

function Strategy:_bindClock()
	if self.timerConn then
		self.timerConn:Disconnect()
	end
	self.timer = timerValue()
	self.timerRaw = self.timer and tonumber(self.timer.Value) or 0
	self.timerAt = Workspace:GetServerTimeNow()
	if self.timer then
		self.timerConn = self.timer:GetPropertyChangedSignal("Value"):Connect(function()
			self.timerRaw = tonumber(self.timer.Value) or 0
			self.timerAt = Workspace:GetServerTimeNow()
		end)
	end
end

function Strategy:_remaining()
	if self.timer ~= timerValue() then
		self:_bindClock()
	end
	if not self.timer then
		return 0
	end
	return math.max(self.timerRaw - (Workspace:GetServerTimeNow() - self.timerAt), 0)
end

function Strategy:_wait(action, seq)
	while self.running and self.seq == seq do
		local wave = tonumber(gameState.Wave) or 0
		if wave > action.wave or (wave == action.wave and self:_remaining() <= action.time) then
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

function Strategy:_tower(id)
	local tower = self.towers[id]
	if tower and tower.Parent then
		return tower
	end
	return nil
end

function Strategy:_run(action)
	local troops = net.Channel("Troops")
	if action.kind == "place" then
		local model = troops:InvokeServer("Place", {
			Position = action.position,
			Rotation = action.rotation,
		}, action.name)
		if typeof(model) == "Instance" then
			self.towers[action.id] = model
			return true
		end
		return false, model
	elseif action.kind == "skip" then
		return net.Channel("Voting"):InvokeServer("Skip")
	elseif action.kind == "raw" then
		local channel = net.Channel(action.channel)
		local args = self:_resolve(action.args)
		if action.invoke then
			return channel:InvokeServer(action.action, table.unpack(args, 1, args.n or #args))
		end
		channel:FireServer(action.action, table.unpack(args, 1, args.n or #args))
		return true
	end

	local tower = self:_tower(action.id)
	if not tower then
		return false, "Tower " .. tostring(action.id) .. " is missing."
	elseif action.kind == "upgrade" then
		return troops:InvokeServer("Upgrade", "Set", {
			Troop = tower,
			Path = action.path,
		})
	elseif action.kind == "sell" then
		return troops:InvokeServer("Sell", { Troop = tower })
	elseif action.kind == "ability" then
		troops:InvokeServer("Abilities", "Activate", {
			Name = action.name,
			Troop = tower,
			Data = self:_resolve(action.data),
		})
		return true
	elseif action.kind == "target" then
		return troops:InvokeServer("Target", "Set", {
			Troop = tower,
			Target = action.target,
		})
	elseif action.kind == "option" then
		return troops:InvokeServer("Option", "Set", {
			Troop = tower,
			Name = action.name,
			Value = self:_resolve(action.value),
		})
	end
	return false, "Unknown action " .. tostring(action.kind)
end

function Strategy:Run()
	if self.running then
		return self
	end
	self.running = true
	self.seq = self.seq + 1
	local seq = self.seq
	getgenv().AutoStratRunner = self

	if game.PlaceId == lobbyId then
		self.status = "Preparing matchmaking"
		task.spawn(function()
			local ok, err = self:_matchmake()
			if self.seq == seq and not ok then
				self.running = false
				self.status = tostring(err)
			end
		end)
		return self
	end

	task.spawn(function()
		local ready, readyErr = self:_prepare(seq)
		if not ready then
			if self.seq == seq then
				self.running = false
				self.status = tostring(readyErr or self.status)
			end
			return
		end

		self.status = "Waiting for actions"
		self:_bindClock()
		local failed = false
		for index, action in ipairs(self.actions) do
			if not self:_wait(action, seq) then
				break
			end
			self.status = string.format("Running %s %d/%d", action.kind, index, #self.actions)
			local ok, success, msg = pcall(self._run, self, action)
			if not ok or success == false then
				self.status = tostring(msg or success)
				failed = true
				break
			end
		end
		if self.seq == seq then
			self.running = false
			if not failed then
				self.status = "Complete"
			end
		end
	end)
	return self
end

function Strategy:Stop()
	self.seq = self.seq + 1
	self.running = false
	self.status = "Stopped"
	if self.timerConn then
		self.timerConn:Disconnect()
		self.timerConn = nil
	end
	if getgenv().AutoStratRunner == self then
		getgenv().AutoStratRunner = nil
	end
	return self
end

local previous = getgenv().AutoStratRunner
if previous and type(previous.Stop) == "function" then
	previous:Stop()
end

return Strategy.new()
