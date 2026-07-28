local clone = cloneref or function(value)
	return value
end

local Players = clone(game:GetService("Players"))
local ReplicatedStorage = clone(game:GetService("ReplicatedStorage"))
local RunService = clone(game:GetService("RunService"))
local TextService = clone(game:GetService("TextService"))
local UIS = clone(game:GetService("UserInputService"))
local Workspace = clone(game:GetService("Workspace"))

local lp = clone(Players.LocalPlayer)
local playerLib
do
	local ok, value = pcall(require, ReplicatedStorage.Client.Modules.Replicators.PlayerReplicator)
	if ok then
		playerLib = value
	end
end

local StrategyHUD = {}
StrategyHUD.__index = StrategyHUD

local function formatNumber(value)
	local out = tostring(math.floor(tonumber(value) or 0))
	while true do
		local nextValue, count = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		out = nextValue
		if count == 0 then
			return out
		end
	end
end

local function formatTime(value)
	local total = math.max(math.floor(tonumber(value) or 0), 0)
	return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

local function towerNames(strategy)
	local names = {}
	local seen = {}
	local function add(value)
		local name = type(value) == "table" and value.Name or value
		name = tostring(name or "")
		if name ~= "" and not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end
	for _, item in ipairs(strategy.loadout) do
		add(item)
	end
	for _, action in ipairs(strategy.actions) do
		if action.kind == "place" then
			add(action.name)
		end
	end
	return names
end

local function towerCounts(strategy)
	local byId = {}
	for _, action in ipairs(strategy.actions) do
		if action.kind == "place" then
			byId[action.id] = action.name
		end
	end

	local counts = {}
	for id, model in pairs(strategy.towers) do
		if model and model.Parent then
			local name = byId[id]
			if name then
				counts[name] = (counts[name] or 0) + 1
			end
		end
	end
	return counts
end

local function readValue(player, names)
	if not player then
		return 0
	end
	for _, name in ipairs(names) do
		local value = player[name]
		if value == nil and type(player.Data) == "table" then
			value = player.Data[name]
		end
		if value == nil and type(player.Stats) == "table" then
			value = player.Stats[name]
		end
		if value == nil and player.Replicator then
			value = player.Replicator:Get(name)
		end
		if type(value) == "table" then
			value = value.Value or value.Amount
		end
		if value ~= nil then
			return value
		end
	end
	return 0
end

local function resetLibrary(library)
	local container = library.container
	local screen = container and container:FindFirstAncestorOfClass("ScreenGui")
	if screen then
		screen:Destroy()
	end
	library.container = nil
	library.count = 0
	library.toggled = true
	library.binding = false
	table.clear(library.queue)
	table.clear(library.callbacks)
	table.clear(library.rainbowtable)
	table.clear(library.binds)
end

function StrategyHUD.new(options)
	local self = setmetatable({
		abort = options.abort,
		alive = true,
		cameraConnections = {},
		connections = {},
		gameState = options.gameState,
		library = options.library,
		rows = {},
		startedAt = Workspace:GetServerTimeNow(),
		strategy = options.strategy,
		towerNames = towerNames(options.strategy),
	}, StrategyHUD)

	resetLibrary(self.library)
	self:_build()
	self:_bind()
	self:Refresh()
	self:_animateBanner()
	return self
end

function StrategyHUD:_row(window, key, name)
	local label = window:Section(name .. ": 0")
	label.Name = name
	self.rows[key] = label
end

function StrategyHUD:_spacer(window)
	self.library:Create("Frame", {
		Name = "Spacer",
		BackgroundTransparency = 1,
		LayoutOrder = window:GetOrder(),
		Parent = window.container,
		Size = UDim2.new(1, 0, 0, 4),
	})
	window:Resize()
end

function StrategyHUD:_build()
	local stats = self.library:CreateWindow("Auto Strats", {})
	for _, name in ipairs(self.towerNames) do
		self:_row(stats, "tower:" .. name, name)
	end
	self:_spacer(stats)
	for _, name in ipairs({ "Coins", "Gems", "Triumphs", "Losses", "Level", "Map" }) do
		self:_row(stats, "stat:" .. name, name)
	end
	self:_spacer(stats)
	self:_row(stats, "stat:Time Passed", "Time Passed")
	stats:Button("Abort Strat", function()
		if self.alive then
			self.abort()
		end
	end)

	local camera = self.library:CreateWindow("Camera")
	camera:Button("Normal", function()
		self:_normalCamera()
	end)
	camera:Button("Follow Enemies", function()
		self:_followEnemies()
	end)
	camera:Button("Free Cam", function()
		self:_freeCamera()
	end)

	local container = self.library.container
	local screen = container.Parent
	screen.Name = "AutoStratUI"
	screen.DisplayOrder = 2147483647
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Global

	local bannerHeight = 34
	local banner = self.library:Create("Frame", {
		Name = "Advertisement",
		BackgroundColor3 = Color3.fromRGB(65, 58, 48),
		BackgroundTransparency = 0.18,
		BorderColor3 = Color3.fromRGB(88, 78, 64),
		BorderSizePixel = 1,
		ClipsDescendants = true,
		Parent = screen,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 0, bannerHeight),
		ZIndex = 20,
	})
	local message = "Auto Strats made by Money Maker, get script on Money Maker Development discord"
	local textWidth =
		TextService:GetTextSize(message, 15, Enum.Font.SourceSansBold, Vector2.new(2000, bannerHeight)).X
	local arrowWidth = 42
	local gap = 7
	-- centered with math because eyeballing it lasted several business days
	local contentWidth = textWidth + (arrowWidth * 2) + (gap * 2)
	local content = self.library:Create("Frame", {
		Name = "Content",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Parent = banner,
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(contentWidth, bannerHeight),
		ZIndex = 21,
	})
	local scale = self.library:Create("UIScale", {
		Name = "Scale",
		Parent = content,
	})
	local function textLabel(name, text, position, size, alignment)
		return self.library:Create("TextLabel", {
			Name = name,
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			Parent = content,
			Position = position,
			Size = size,
			Text = text,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 15,
			TextStrokeTransparency = 1,
			TextXAlignment = alignment or Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			ZIndex = 22,
		})
	end

	self.leftArrow = textLabel(
		"LeftArrow",
		"--->",
		UDim2.fromOffset(0, 0),
		UDim2.fromOffset(arrowWidth, bannerHeight),
		Enum.TextXAlignment.Right
	)
	textLabel(
		"Message",
		message,
		UDim2.fromOffset(arrowWidth + gap, 0),
		UDim2.fromOffset(textWidth, bannerHeight)
	)
	self.rightArrow = textLabel(
		"RightArrow",
		"<---",
		UDim2.fromOffset(arrowWidth + gap + textWidth + gap, 0),
		UDim2.fromOffset(arrowWidth, bannerHeight),
		Enum.TextXAlignment.Left
	)
	self.banner = banner

	local function layout()
		if not self.alive or not banner.Parent then
			return
		end
		container.Position = UDim2.fromOffset(-8, bannerHeight + 8)
		banner.Position = UDim2.fromOffset(0, 0)
		banner.Size = UDim2.new(1, 0, 0, bannerHeight)
		scale.Scale = math.min(1, math.max((banner.AbsoluteSize.X - 16) / contentWidth, 0.55))
	end
	self.connections[#self.connections + 1] = container:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	self.connections[#self.connections + 1] = banner:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	layout()

	self.library.queue[#self.library.queue + 1] = {
		w = banner,
		p = banner.Position,
	}
end

function StrategyHUD:_bind()
	local elapsed = 0
	self.connections[#self.connections + 1] = RunService.Heartbeat:Connect(function(delta)
		if not self.alive then
			return
		end

		elapsed = elapsed + delta
		if elapsed < 1 then
			return
		end
		elapsed = elapsed % 1
		self:Refresh()
	end)
end

function StrategyHUD:_animateBanner()
	-- this banner has somehow had more revisions than the strategy runner
	local blinkTime = 1
	local dashTime = 0.3
	local dashPause = 0.45
	local loopPause = 0.75
	local frames = {
		{ loopPause, "--->", "<---", 0 },
	}
	for _ = 1, 3 do
		frames[#frames + 1] = { blinkTime, nil, nil, 1 }
		frames[#frames + 1] = { blinkTime, nil, nil, 0 }
	end

	local dashCount = 3
	for _ = 1, 3 do
		for pass = 1, 2 do
			local step = pass == 1 and -1 or 1
			for _ = 1, 3 do
				dashCount = dashCount + step
				frames[#frames + 1] = {
					dashTime,
					string.rep("-", dashCount) .. ">",
					"<" .. string.rep("-", dashCount),
					0,
				}
			end
		end
		frames[#frames + 1] = { dashPause, "--->", "<---", 0 }
	end

	local frame = 1
	local elapsed = 0
	local function show(data)
		if data[2] then
			self.leftArrow.Text = data[2]
			self.rightArrow.Text = data[3]
		end
		self.leftArrow.TextTransparency = data[4]
		self.rightArrow.TextTransparency = data[4]
	end

	show(frames[frame])
	self.connections[#self.connections + 1] = RunService.Heartbeat:Connect(function(delta)
		if not self.alive then
			return
		end

		elapsed = elapsed + delta
		while elapsed >= frames[frame][1] do
			elapsed = elapsed - frames[frame][1]
			frame = (frame % #frames) + 1
			show(frames[frame])
		end
	end)
end

function StrategyHUD:_setRow(key, name, value)
	local row = self.rows[key]
	if row then
		row.Text = string.format("%s: %s", name, tostring(value))
	end
end

function StrategyHUD:Refresh()
	if not self.alive then
		return
	end

	local counts = towerCounts(self.strategy)
	for _, name in ipairs(self.towerNames) do
		self:_setRow("tower:" .. name, name, formatNumber(counts[name] or 0))
	end

	local player = playerLib and playerLib.GetLocalPlayerRaw()
	self:_setRow("stat:Coins", "Coins", formatNumber(readValue(player, { "Coins", "Currency" })))
	self:_setRow("stat:Gems", "Gems", formatNumber(readValue(player, { "Gems" })))
	self:_setRow("stat:Triumphs", "Triumphs", formatNumber(readValue(player, { "Triumphs", "Wins" })))
	self:_setRow("stat:Losses", "Losses", formatNumber(readValue(player, { "Losses" })))
	self:_setRow("stat:Level", "Level", formatNumber(readValue(player, { "Level", "Rank" })))
	self:_setRow("stat:Map", "Map", tostring(self.gameState.MapName or self.strategy.meta.Map or "Unknown"))
	self:_setRow("stat:Time Passed", "Time Passed", formatTime(Workspace:GetServerTimeNow() - self.startedAt))
end

function StrategyHUD:_clearCamera()
	for _, connection in ipairs(self.cameraConnections) do
		connection:Disconnect()
	end
	table.clear(self.cameraConnections)
	UIS.MouseBehavior = Enum.MouseBehavior.Default
end

function StrategyHUD:_normalCamera()
	self:_clearCamera()
	self.cameraTouched = true
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local char = lp.Character
	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = char and (char:FindFirstChildOfClass("Humanoid") or char:FindFirstChild("HumanoidRootPart"))
end

function StrategyHUD:_enemyFolder()
	return Workspace:FindFirstChild("NPCs") or Workspace:FindFirstChild("Enemies")
end

function StrategyHUD:_enemySubject()
	local folder = self:_enemyFolder()
	if not folder then
		return nil
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local hum = model:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health > 0 then
				return hum
					or model.PrimaryPart
					or model:FindFirstChild("HumanoidRootPart")
					or model:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
end

function StrategyHUD:_followEnemies()
	self:_clearCamera()
	self.cameraTouched = true
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	camera.CameraType = Enum.CameraType.Custom

	local function update()
		if not self.alive then
			return
		end
		local subject = self:_enemySubject()
		if subject then
			camera.CameraSubject = subject
		end
	end
	local folder = self:_enemyFolder()
	if folder then
		self.cameraConnections[#self.cameraConnections + 1] = folder.ChildAdded:Connect(function()
			task.defer(update)
		end)
		self.cameraConnections[#self.cameraConnections + 1] = folder.ChildRemoved:Connect(function()
			task.defer(update)
		end)
	else
		self.cameraConnections[#self.cameraConnections + 1] = Workspace.ChildAdded:Connect(function(child)
			if child.Name == "NPCs" or child.Name == "Enemies" then
				self:_followEnemies()
			end
		end)
	end
	update()
end

function StrategyHUD:_freeCamera()
	self:_clearCamera()
	self.cameraTouched = true
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local position = camera.CFrame.Position
	local pitch, yaw = camera.CFrame:ToOrientation()
	local held = {}
	local turning = false

	self.cameraConnections[#self.cameraConnections + 1] = UIS.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			turning = true
			UIS.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		else
			held[input.KeyCode] = true
		end
	end)
	self.cameraConnections[#self.cameraConnections + 1] = UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			turning = false
			UIS.MouseBehavior = Enum.MouseBehavior.Default
		else
			held[input.KeyCode] = nil
		end
	end)
	self.cameraConnections[#self.cameraConnections + 1] = RunService.RenderStepped:Connect(function(delta)
		if turning then
			local mouse = UIS:GetMouseDelta()
			yaw = yaw - mouse.X * 0.0025
			pitch = math.clamp(pitch - mouse.Y * 0.0025, -1.5, 1.5)
		end

		local x = (held[Enum.KeyCode.D] and 1 or 0) - (held[Enum.KeyCode.A] and 1 or 0)
		local y = (held[Enum.KeyCode.E] and 1 or 0) - (held[Enum.KeyCode.Q] and 1 or 0)
		local z = (held[Enum.KeyCode.S] and 1 or 0) - (held[Enum.KeyCode.W] and 1 or 0)
		local move = Vector3.new(x, y, z)
		local rotation = CFrame.fromOrientation(pitch, yaw, 0)
		if move.Magnitude > 0 then
			local speed = held[Enum.KeyCode.LeftShift] and 140 or 55
			position = position + rotation:VectorToWorldSpace(move.Unit) * speed * delta
		end
		camera.CFrame = CFrame.new(position) * rotation
	end)
end

function StrategyHUD:Destroy()
	if not self.alive then
		return
	end
	self.alive = false
	if self.cameraTouched then
		self:_normalCamera()
	else
		self:_clearCamera()
	end
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	table.clear(self.connections)
	resetLibrary(self.library)
end

return StrategyHUD
