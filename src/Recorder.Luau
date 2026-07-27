local clone = cloneref or function(value)
	return value
end

local Players = clone(game:GetService("Players"))
local ReplicatedStorage = clone(game:GetService("ReplicatedStorage"))
local TeleportService = clone(game:GetService("TeleportService"))
local Workspace = clone(game:GetService("Workspace"))

local lp = clone(Players.LocalPlayer)
local net = require(ReplicatedStorage.Shared.Modules.Network)
local gameState = require(ReplicatedStorage.Shared.Modules.GameState)
local playerLib = require(ReplicatedStorage.Client.Modules.Replicators.PlayerReplicator)
local towerLib = require(ReplicatedStorage.Client.Modules.Replicators.TowerReplicator)

local Recorder = {}
Recorder.__index = Recorder

local watched = {
	LobbyVoting = true,
	Troops = true,
	Voting = true,
}

local names = {
	abilities = "ability",
	option = "option",
	place = "place",
	sell = "sell",
	target = "target",
	upgrade = "upgrade",
}

local function cleanName(value)
	local name = tostring(value or ""):gsub("[^%w%s_%-]", ""):match("^%s*(.-)%s*$")
	return name ~= "" and name or "MyStrategy"
end

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

local function timerValue()
	local state = ReplicatedStorage:FindFirstChild("State")
	local timer = state and state:FindFirstChild("Timer")
	return timer and timer:FindFirstChild("Time")
end

local function towerModel(value)
	if typeof(value) ~= "Instance" then
		return nil
	end
	local towers = Workspace:FindFirstChild("Towers")
	if not towers then
		return nil
	end
	local model = value
	while model and model.Parent ~= towers do
		model = model.Parent
	end
	return model
end

local function towerInfo(model)
	local tower = model and towerLib.getTowerByModel(model)
	if not tower then
		return nil
	end
	return tower, tower.TowerName, tower.GoldenPerks == true
end

local function loadout()
	local player = playerLib.GetLocalPlayerRaw()
	local equipped = player and player.EquippedTowers or {}
	local inventory = {}
	local ok, cache = pcall(require, ReplicatedStorage.Client.Modules.Cache)
	if ok then
		local item = cache("Inventory.Troops")
		inventory = item and item:GetValue() or {}
	end

	local out = {}
	for slot = 1, 6 do
		local name = equipped[slot]
		if name then
			local owned = inventory[name]
			out[#out + 1] = {
				Name = name,
				Golden = type(owned) == "table" and owned.GoldenPerks == true,
			}
		end
	end
	return out
end

local function metadata()
	local data = TeleportService:GetLocalPlayerTeleportData() or {}
	local function pick(...)
		for index = 1, select("#", ...) do
			local value = select(index, ...)
			if value ~= nil and value ~= "" then
				return value
			end
		end
		return ""
	end
	local map = pick(gameState.MapName, data.Map)
	local mode = pick(gameState.GameMode, data.Mode)
	local difficulty = pick(gameState.Difficulty, data.Difficulty)
	return {
		Map = map,
		Mode = mode,
		Difficulty = difficulty,
		Loadout = loadout(),
	}
end

function Recorder.new()
	return setmetatable({
		active = false,
		actions = {},
		installed = false,
		last = "Nothing recorded yet.",
		meta = metadata(),
		name = "MyStrategy",
		nextTower = 0,
		status = "Ready to record a strategy.",
		towerIds = setmetatable({}, { __mode = "k" }),
	}, Recorder)
end

function Recorder:_bindClock()
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

function Recorder:_stamp()
	if self.timer ~= timerValue() then
		self:_bindClock()
	end
	local left = self.timerRaw or 0
	if self.timer then
		left = math.max(left - (Workspace:GetServerTimeNow() - self.timerAt), 0)
	end
	local total = math.floor(left * 1000 + 0.5)
	return {
		wave = math.max(tonumber(gameState.Wave) or 0, 0),
		minute = math.floor(total / 60000),
		second = math.floor(total / 1000) % 60,
		millisecond = total % 1000,
	}
end

function Recorder:_push(kind, value)
	value.kind = kind
	value.at = self:_stamp()
	value.seq = #self.actions + 1
	self.actions[value.seq] = value
	self.last = string.format("%s #%d", names[kind] or kind, value.seq)
	self.status = string.format("Recording %s", self.name)
end

function Recorder:_snapshot(value, seen)
	local kind = typeof(value)
	if kind == "Instance" then
		local model = self.towerIds[value] and value or towerModel(value)
		local id = model and self.towerIds[model]
		if id then
			return { __kind = "tower", id = id }
		end
		return { __kind = "instance", path = value:GetFullName() }
	elseif kind == "EnumItem" then
		return { __kind = "enum", path = tostring(value) }
	elseif kind ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return "<cycle>"
	end
	seen[value] = true
	local out = {}
	for key, item in pairs(value) do
		out[self:_snapshot(key, seen)] = self:_snapshot(item, seen)
	end
	seen[value] = nil
	return out
end

function Recorder:_literal(value, seen)
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

	if value.__kind == "tower" then
		return string.format("TDS:Tower(%d)", value.id)
	elseif value.__kind == "instance" then
		return "TDS:Find(" .. quote(value.path) .. ")"
	elseif value.__kind == "enum" then
		return "TDS:Enum(" .. quote(value.path) .. ")"
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

function Recorder:_golden(name)
	for _, item in ipairs(self.meta.Loadout or {}) do
		if item.Name == name then
			return item.Golden == true
		end
	end
	local ok, cache = pcall(require, ReplicatedStorage.Client.Modules.Cache)
	if not ok then
		return false
	end
	local inventory = cache("Inventory.Troops"):GetValue()
	local item = type(inventory) == "table" and inventory[name]
	return type(item) == "table" and item.GoldenPerks == true
end

function Recorder:_id(model)
	local direct = self.towerIds[model]
	if direct then
		return direct
	end
	model = towerModel(model)
	if not model then
		return nil
	end
	local id = self.towerIds[model]
	if id then
		return id
	end

	local tower, name, golden = towerInfo(model)
	if not tower or tower.OwnerId ~= lp.UserId then
		return nil
	end
	self.nextTower = self.nextTower + 1
	id = self.nextTower
	self.towerIds[model] = id

	local pivot = model:GetPivot()
	self:_push("place", {
		id = id,
		name = name,
		position = pivot.Position,
		rotation = pivot - pivot.Position,
		golden = golden,
		existing = true,
	})
	return id
end

function Recorder:_placed(model, placement, name)
	model = towerModel(model)
	if not model then
		return
	end
	local id = self.towerIds[model]
	if not id then
		self.nextTower = self.nextTower + 1
		id = self.nextTower
		self.towerIds[model] = id
	end
	self:_push("place", {
		id = id,
		name = name,
		position = placement.Position,
		rotation = placement.Rotation,
		golden = self:_golden(name),
	})
end

function Recorder:_raw(channel, action, args, invoke)
	if not watched[channel] then
		return
	end
	self:_push("raw", {
		channel = channel,
		action = action,
		args = self:_snapshot(args),
		invoke = invoke,
	})
end

function Recorder:_captureInvoke(channel, action, args, result)
	if not self.active then
		return
	end

	if channel == "Troops" then
		local mode = args[1]
		local data = args[2]
		if action == "Place" then
			if typeof(result[1]) == "Instance" and type(mode) == "table" then
				self:_placed(result[1], mode, data)
			end
			return
		elseif action == "Upgrade" then
			if result[1] == true and type(data) == "table" then
				local id = self:_id(data.Troop)
				if id then
					self:_push("upgrade", { id = id, path = tonumber(data.Path) or 0 })
				end
			end
			return
		elseif action == "Sell" then
			if result[1] == true and type(mode) == "table" then
				local id = self:_id(mode.Troop)
				if id then
					self:_push("sell", { id = id })
				end
			end
			return
		elseif action == "Abilities" and mode == "Activate" and type(data) == "table" then
			local id = self:_id(data.Troop)
			if id then
				self:_push("ability", {
					id = id,
					name = data.Name,
					data = self:_snapshot(data.Data or {}),
				})
			end
			return
		elseif action == "Target" then
			if result[1] and type(data) == "table" then
				local id = self:_id(data.Troop)
				if id then
					self:_push("target", { id = id, target = data.Target })
				end
			end
			return
		elseif action == "Option" then
			if result[1] == true and type(data) == "table" then
				local id = self:_id(data.Troop)
				if id then
					self:_push("option", {
						id = id,
						name = data.Name,
						value = self:_snapshot(data.Value),
					})
				end
			end
			return
		end
	elseif channel == "Voting" and action == "Skip" then
		if result[1] == true then
			self:_push("skip", {})
		end
		return
	end

	self:_raw(channel, action, args, true)
end

function Recorder:_captureFire(channel, action, args)
	if self.active then
		self:_raw(channel, action, args, false)
	end
end

function Recorder:Install()
	if self.installed then
		return true
	end
	if type(hookfunction) ~= "function" then
		self.status = "Recorder needs hookfunction."
		return false
	end

	local channel = net.Channel("Troops")
	local mt = getmetatable(channel)
	local methods = mt and mt.__index
	local invoke = type(methods) == "table" and methods.InvokeServer
	local fire = type(methods) == "table" and methods.FireServer
	if type(invoke) ~= "function" or type(fire) ~= "function" then
		self.status = "TDS network methods were not found."
		return false
	end

	local okInvoke, oldInvoke = pcall(hookfunction, invoke, function(ch, action, ...)
		local args = table.pack(...)
		local result = table.pack(self.oldInvoke(ch, action, ...))
		local ok, err = pcall(self._captureInvoke, self, ch.Channel, action, args, result)
		if not ok then
			self.status = "Recorder hook error: " .. tostring(err)
		end
		return table.unpack(result, 1, result.n)
	end)
	if not okInvoke or type(oldInvoke) ~= "function" then
		self.status = "Could not hook InvokeServer: " .. tostring(oldInvoke)
		return false
	end
	self.oldInvoke = oldInvoke
	self.invoke = invoke

	local okFire, oldFire = pcall(hookfunction, fire, function(ch, action, ...)
		local args = table.pack(...)
		self.oldFire(ch, action, ...)
		local ok, err = pcall(self._captureFire, self, ch.Channel, action, args)
		if not ok then
			self.status = "Recorder hook error: " .. tostring(err)
		end
	end)
	if not okFire or type(oldFire) ~= "function" then
		pcall(hookfunction, invoke, oldInvoke)
		self.invoke = nil
		self.oldInvoke = nil
		self.status = "Could not hook FireServer: " .. tostring(oldFire)
		return false
	end
	self.oldFire = oldFire
	self.fire = fire
	self.installed = true
	return true
end

function Recorder:_captureExisting()
	local towers = Workspace:FindFirstChild("Towers")
	if not towers then
		return 0
	end
	local found = {}
	for _, model in ipairs(towers:GetChildren()) do
		local tower = towerLib.getTowerByModel(model)
		if tower and tower.OwnerId == lp.UserId and tower:IsAlive() then
			found[#found + 1] = model
		end
	end
	table.sort(found, function(a, b)
		local left = towerLib.getTowerByModel(a)
		local right = towerLib.getTowerByModel(b)
		return tostring(left and left.Replicator:Get("UID") or a) < tostring(right and right.Replicator:Get("UID") or b)
	end)
	for _, model in ipairs(found) do
		self:_id(model)
	end
	return #found
end

function Recorder:Start(name)
	if not self:Install() then
		return false
	end
	self.name = cleanName(name or self.name)
	self.actions = {}
	self.nextTower = 0
	self.towerIds = setmetatable({}, { __mode = "k" })
	self.meta = metadata()
	self.active = true
	self.last = "Waiting for your first action."
	self:_bindClock()
	local existing = self:_captureExisting()
	self.status = existing > 0 and string.format("Recording %s; captured %d placed tower(s).", self.name, existing)
		or "Recording " .. self.name
	return true
end

function Recorder:Stop()
	self.active = false
	self.status = string.format("Stopped with %d action(s).", #self.actions)
	return self
end

function Recorder:Clear()
	self.actions = {}
	self.nextTower = 0
	self.towerIds = setmetatable({}, { __mode = "k" })
	self.last = "Nothing recorded yet."
	self.status = self.active and "Recording " .. self.name or "Recorder cleared."
	return self
end

function Recorder:SetName(value)
	self.name = cleanName(value)
	return self
end

function Recorder:_at(action)
	local at = action.at
	return string.format("%d, %d, %d, %d", at.wave, at.minute, at.second, at.millisecond)
end

function Recorder:_line(action)
	local at = self:_at(action)
	if action.kind == "place" then
		return string.format(
			"TDS:Place(%s, %s, %s, %s, %s, %s, %s)",
			quote(action.name),
			number(action.position.X),
			number(action.position.Y),
			number(action.position.Z),
			at,
			self:_literal(action.rotation),
			tostring(action.golden == true)
		)
	elseif action.kind == "upgrade" then
		return string.format("TDS:Upgrade(%d, %s, %d)", action.id, at, action.path)
	elseif action.kind == "sell" then
		return string.format("TDS:Sell(%d, %s)", action.id, at)
	elseif action.kind == "ability" then
		return string.format(
			"TDS:Ability(%d, %s, %s, %s)",
			action.id,
			quote(action.name),
			at,
			self:_literal(action.data)
		)
	elseif action.kind == "skip" then
		return "TDS:Skip(" .. at .. ")"
	elseif action.kind == "target" then
		return string.format("TDS:Target(%d, %s, %s)", action.id, quote(action.target), at)
	elseif action.kind == "option" then
		return string.format(
			"TDS:Option(%d, %s, %s, %s)",
			action.id,
			quote(action.name),
			self:_literal(action.value),
			at
		)
	elseif action.kind == "raw" then
		return string.format(
			"TDS:Raw(%s, %s, %s, %s, %s)",
			quote(action.channel),
			quote(action.action),
			self:_literal(action.args),
			at,
			tostring(action.invoke)
		)
	end
end

function Recorder:Export()
	local latest = metadata()
	if latest.Map ~= "" then
		self.meta.Map = latest.Map
	end
	if latest.Mode ~= "" then
		self.meta.Mode = latest.Mode
	end
	if latest.Difficulty ~= "" then
		self.meta.Difficulty = latest.Difficulty
	end
	if #latest.Loadout > 0 then
		self.meta.Loadout = latest.Loadout
	end

	local lines = {
		'local TDS = loadstring(game:HttpGet("https://raw.githubusercontent.com/tessa-says-hi/auto-strat/main/src/Strategy.Luau", true))()',
		"TDS:Name(" .. quote(self.name) .. ")",
	}
	local loadoutArgs = {}
	for _, item in ipairs(self.meta.Loadout or {}) do
		loadoutArgs[#loadoutArgs + 1] =
			string.format("{ Name = %s, Golden = %s }", quote(item.Name), tostring(item.Golden == true))
	end
	lines[#lines + 1] = "TDS:Loadout(" .. table.concat(loadoutArgs, ", ") .. ")"
	lines[#lines + 1] = string.format(
		"TDS:Map(%s, true, %s, %s)",
		quote(self.meta.Map),
		quote(self.meta.Mode),
		quote(self.meta.Difficulty)
	)
	for _, action in ipairs(self.actions) do
		local line = self:_line(action)
		if line then
			lines[#lines + 1] = line
		end
	end
	lines[#lines + 1] = "TDS:Run()"
	return table.concat(lines, "\n") .. "\n"
end

function Recorder:Copy()
	if type(setclipboard) ~= "function" then
		self.status = "This executor does not support setclipboard."
		return false
	end
	setclipboard(self:Export())
	self.status = string.format("Copied %d action(s) to clipboard.", #self.actions)
	return true
end

function Recorder:Save()
	if type(writefile) ~= "function" then
		self.status = "This executor does not support writefile."
		return false
	end
	local folder = "auto-strat"
	local file = folder .. "/" .. cleanName(self.name):gsub("%s+", "_") .. ".luau"
	local ok, err = pcall(function()
		if type(isfolder) == "function" and type(makefolder) == "function" and not isfolder(folder) then
			makefolder(folder)
		end
		writefile(file, self:Export())
	end)
	if not ok then
		self.status = "Save failed: " .. tostring(err)
		return false
	end
	self.status = "Saved " .. file
	return true, file
end

function Recorder:Status()
	return string.format("%s\n%d action(s) | %s", self.status, #self.actions, self.last)
end

function Recorder:Destroy()
	self.active = false
	if self.timerConn then
		self.timerConn:Disconnect()
		self.timerConn = nil
	end
	if self.invoke and self.oldInvoke and type(hookfunction) == "function" then
		pcall(hookfunction, self.invoke, self.oldInvoke)
	end
	if self.fire and self.oldFire and type(hookfunction) == "function" then
		pcall(hookfunction, self.fire, self.oldFire)
	end
	self.installed = false
	self.invoke = nil
	self.oldInvoke = nil
	self.fire = nil
	self.oldFire = nil
	return self
end

return Recorder
