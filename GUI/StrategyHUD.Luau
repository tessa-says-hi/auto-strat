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
local BANNER_FONT = Enum.Font.GothamBold
local BANNER_TEXT_SIZE = 15
local PLAYER_STATS = {
	{ name = "Coins", fields = { "Coins", "Currency" } },
	{ name = "Gems", fields = { "Gems" } },
	{ name = "Triumphs", fields = { "Triumphs", "Wins" } },
	{ name = "Losses", fields = { "Losses" } },
	{ name = "Level", fields = { "Level", "Rank" } },
}
local playerLib
do
	local ok, value = pcall(require, ReplicatedStorage.Client.Modules.Replicators.PlayerReplicator)
	if ok then
		playerLib = value
	end
end

local npcLib
do
	local ok, value = pcall(function()
		return require(ReplicatedStorage.Client.Modules.Replicators.NPCReplicator)
	end)
	if ok then
		npcLib = value
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

local function towerData(strategy)
	local names = {}
	local byId = {}
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
			byId[action.id] = action.name
		end
	end
	return names, byId
end

local function towerCounts(towers, byId)
	local counts = {}
	for id, model in pairs(towers) do
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

local function track(connections, signal, callback)
	local connection = signal:Connect(callback)
	connections[#connections + 1] = connection
end

local function disconnectAll(connections)
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
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
	local names, byId = towerData(options.strategy)
	local self = setmetatable({
		abort = options.abort,
		alive = true,
		cameraConnections = {},
		connections = {},
		freeCameraSpeed = 55,
		gameState = options.gameState,
		library = options.library,
		rowNames = {},
		rowText = {},
		rows = {},
		startedAt = Workspace:GetServerTimeNow(),
		strategy = options.strategy,
		towerNameById = byId,
		towerNames = names,
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
	self.rowNames[key] = name
	self.rows[key] = label
end

function StrategyHUD:_build()
	local stats = self.library:CreateWindow("Auto Strats", {})
	for _, name in ipairs(self.towerNames) do
		self:_row(stats, "tower:" .. name, name)
	end
	stats:Section("")
	for _, stat in ipairs(PLAYER_STATS) do
		self:_row(stats, "stat:" .. stat.name, stat.name)
	end
	self:_row(stats, "stat:Map", "Map")
	stats:Section("")
	self:_row(stats, "stat:Time Passed", "Time Passed")
	stats:Section("")
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
	local textWidth = TextService:GetTextSize(message, BANNER_TEXT_SIZE, BANNER_FONT, Vector2.new(2000, bannerHeight)).X
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
			Font = BANNER_FONT,
			Parent = content,
			Position = position,
			Size = size,
			Text = text,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = BANNER_TEXT_SIZE,
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
	track(self.connections, container:GetPropertyChangedSignal("AbsoluteSize"), layout)
	track(self.connections, banner:GetPropertyChangedSignal("AbsoluteSize"), layout)
	layout()

	self.library.queue[#self.library.queue + 1] = {
		w = banner,
		p = banner.Position,
	}
end

function StrategyHUD:_bind()
	task.spawn(function()
		while self.alive do
			task.wait(1)
			if self.alive then
				self:Refresh()
			end
		end
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

	local function show(data)
		if data[2] then
			self.leftArrow.Text = data[2]
			self.rightArrow.Text = data[3]
		end
		self.leftArrow.TextTransparency = data[4]
		self.rightArrow.TextTransparency = data[4]
	end

	task.spawn(function()
		local frame = 1
		while self.alive do
			local data = frames[frame]
			show(data)
			task.wait(data[1])
			frame = (frame % #frames) + 1
		end
	end)
end

function StrategyHUD:_setRow(key, value)
	local row = self.rows[key]
	if not row then
		return
	end

	local text = string.format("%s: %s", self.rowNames[key], tostring(value))
	if self.rowText[key] ~= text then
		row.Text = text
		self.rowText[key] = text
	end
end

function StrategyHUD:Refresh()
	if not self.alive then
		return
	end

	local counts = towerCounts(self.strategy.towers, self.towerNameById)
	for _, name in ipairs(self.towerNames) do
		self:_setRow("tower:" .. name, formatNumber(counts[name] or 0))
	end

	local player = playerLib and playerLib.GetLocalPlayerRaw()
	for _, stat in ipairs(PLAYER_STATS) do
		self:_setRow("stat:" .. stat.name, formatNumber(readValue(player, stat.fields)))
	end
	self:_setRow("stat:Map", tostring(self.gameState.MapName or self.strategy.meta.Map or "Unknown"))
	self:_setRow("stat:Time Passed", formatTime(Workspace:GetServerTimeNow() - self.startedAt))
end

function StrategyHUD:_captureCameraState()
	if self.cameraState then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	self.cameraState = {
		fieldOfView = camera.FieldOfView,
		mouseBehavior = UIS.MouseBehavior,
		mouseIconEnabled = UIS.MouseIconEnabled,
	}
end

function StrategyHUD:_clearCamera()
	disconnectAll(self.cameraConnections)

	local state = self.cameraState
	UIS.MouseBehavior = state and state.mouseBehavior or Enum.MouseBehavior.Default
	UIS.MouseIconEnabled = state == nil or state.mouseIconEnabled
end

function StrategyHUD:_normalCamera()
	self:_captureCameraState()
	self:_clearCamera()
	self.cameraTouched = true
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	if self.cameraState then
		camera.FieldOfView = self.cameraState.fieldOfView
	end

	local function useCharacter(character)
		local subject = character
			and (character:FindFirstChildOfClass("Humanoid") or character:FindFirstChild("HumanoidRootPart"))
		if not subject then
			return false
		end
		camera.CameraSubject = subject
		camera.CameraType = Enum.CameraType.Custom
		return true
	end

	if not useCharacter(lp.Character) then
		camera.CameraType = Enum.CameraType.Custom
		if self.alive then
			track(self.cameraConnections, lp.CharacterAdded, function(character)
				if useCharacter(character) then
					self:_clearCamera()
				end
			end)
		end
	end
end

function StrategyHUD:_enemyFolder()
	return Workspace:FindFirstChild("NPCs") or Workspace:FindFirstChild("Enemies")
end

function StrategyHUD:_enemyInfo(model)
	if not model:IsA("Model") or not model:FindFirstChild("RootPointer") then
		return nil
	end

	local npc
	if npcLib and npcLib.GetNPCFromModel then
		local ok, value = pcall(npcLib.GetNPCFromModel, model)
		if ok then
			npc = value
		end
	end

	if npc then
		if npc.Type == "Units" or (tonumber(npc.Health) or 0) <= 0 then
			return nil
		end
	end

	local part = (npc and (npc.PrimaryPart or npc.HumanoidRootPart))
		or model.PrimaryPart
		or model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChildWhichIsA("BasePart", true)
	if not part or not part.Parent then
		return nil
	end

	return part, tonumber(npc and npc.PathDistance) or tonumber(model:GetAttribute("PathDistance")) or 0
end

function StrategyHUD:_leadingEnemy(current)
	local folder = self:_enemyFolder()
	if not folder then
		return nil, nil
	end

	local bestPart
	local bestModel
	local bestScore = -math.huge
	for _, model in ipairs(folder:GetChildren()) do
		local part, score = self:_enemyInfo(model)
		if part then
			-- A tiny tie-break keeps the camera from changing targets just because two enemies share a path marker.
			local stableScore = score + (model == current and 0.001 or 0)
			if stableScore > bestScore then
				bestPart = part
				bestModel = model
				bestScore = stableScore
			end
		end
	end
	return bestPart, bestModel
end

function StrategyHUD:_followEnemies()
	self:_captureCameraState()
	self:_clearCamera()
	self.cameraTouched = true
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local targetPart
	local targetModel
	local rescanAt = 0

	track(self.cameraConnections, RunService.RenderStepped, function(delta)
		if not self.alive then
			return
		end

		rescanAt = rescanAt - delta
		if rescanAt <= 0 or not targetPart or not targetPart.Parent then
			targetPart, targetModel = self:_leadingEnemy(targetModel)
			rescanAt = 0.2
		end
		if not targetPart or not targetModel or not targetModel.Parent then
			return
		end

		local size = targetModel:GetExtentsSize()
		local distance = math.clamp(size.Magnitude * 1.4, 14, 34)
		local height = math.clamp(size.Y * 0.85, 7, 18)
		local focus = targetPart.Position + Vector3.new(0, math.clamp(size.Y * 0.25, 1.5, 6), 0)
		local forward = Vector3.new(targetPart.CFrame.LookVector.X, 0, targetPart.CFrame.LookVector.Z)
		if forward.Magnitude < 0.01 then
			forward = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		end
		forward = forward.Magnitude > 0 and forward.Unit or Vector3.new(0, 0, -1)

		local desiredPosition = focus - forward * distance + Vector3.new(0, height, 0)
		local desired = CFrame.lookAt(desiredPosition, focus)
		local alpha = 1 - math.exp(-8 * math.min(delta, 0.1))
		camera.CFrame = camera.CFrame:Lerp(desired, alpha)
		camera.Focus = CFrame.new(focus)
	end)
end

function StrategyHUD:_freeCamera()
	self:_captureCameraState()
	self:_clearCamera()
	self.cameraTouched = true
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local position = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	local pitch = math.asin(math.clamp(look.Y, -1, 1))
	local yaw = math.atan2(-look.X, -look.Z)
	local targetPitch = pitch
	local targetYaw = yaw
	local velocity = Vector3.new()
	local held = {}
	local turning = false
	local speed = self.freeCameraSpeed

	local function stopTurning()
		turning = false
		local state = self.cameraState
		UIS.MouseBehavior = state and state.mouseBehavior or Enum.MouseBehavior.Default
		UIS.MouseIconEnabled = state == nil or state.mouseIconEnabled
	end

	track(self.cameraConnections, UIS.InputBegan, function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			turning = true
			UIS.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			UIS.MouseIconEnabled = false
			return
		end
		if not processed and input.UserInputType == Enum.UserInputType.Keyboard and not UIS:GetFocusedTextBox() then
			held[input.KeyCode] = true
		end
	end)
	track(self.cameraConnections, UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			stopTurning()
		elseif input.UserInputType == Enum.UserInputType.Keyboard then
			held[input.KeyCode] = nil
		end
	end)
	track(self.cameraConnections, UIS.InputChanged, function(input, processed)
		if not processed and input.UserInputType == Enum.UserInputType.MouseWheel and input.Position.Z ~= 0 then
			speed = math.clamp(speed * (input.Position.Z > 0 and 1.25 or 0.8), 8, 260)
			self.freeCameraSpeed = speed
		end
	end)
	track(self.cameraConnections, UIS.WindowFocusReleased, function()
		table.clear(held)
		stopTurning()
	end)
	track(self.cameraConnections, RunService.RenderStepped, function(delta)
		local step = math.min(delta, 1 / 15)
		if turning then
			local mouse = UIS:GetMouseDelta()
			targetYaw = targetYaw - mouse.X * 0.003
			targetPitch = math.clamp(targetPitch - mouse.Y * 0.003, -1.55, 1.55)
		end

		local turnAlpha = 1 - math.exp(-24 * step)
		yaw = yaw + (targetYaw - yaw) * turnAlpha
		pitch = pitch + (targetPitch - pitch) * turnAlpha
		local rotation = CFrame.fromOrientation(pitch, yaw, 0)

		local forward = (held[Enum.KeyCode.W] and 1 or 0) - (held[Enum.KeyCode.S] and 1 or 0)
		local right = (held[Enum.KeyCode.D] and 1 or 0) - (held[Enum.KeyCode.A] and 1 or 0)
		local vertical = (held[Enum.KeyCode.E] and 1 or 0) - (held[Enum.KeyCode.Q] and 1 or 0)
		local move = rotation.LookVector * forward
			+ rotation.RightVector * right
			+ Vector3.new(0, vertical, 0)
		local multiplier = 1
		if held[Enum.KeyCode.LeftShift] or held[Enum.KeyCode.RightShift] then
			multiplier = 3
		elseif held[Enum.KeyCode.LeftControl] or held[Enum.KeyCode.RightControl] then
			multiplier = 0.25
		end
		local desiredVelocity = move.Magnitude > 0 and move.Unit * speed * multiplier or Vector3.new()

		-- The camera now has inertia instead of moving like it remembered an appointment three maps away.
		local moveAlpha = 1 - math.exp(-(move.Magnitude > 0 and 14 or 10) * step)
		velocity = velocity:Lerp(desiredVelocity, moveAlpha)
		position = position + velocity * step
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		camera.CFrame = CFrame.new(position) * rotation
		camera.Focus = camera.CFrame * CFrame.new(0, 0, -512)
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
	disconnectAll(self.connections)
	resetLibrary(self.library)
end

return StrategyHUD
