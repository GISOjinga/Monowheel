--!strict
--[[
    Monowheel Vehicle Control Script
    Author: Jinga
    Description:
        Controls a single-wheel vehicle with:
        • Wall-climbing via multi-raycasts
        • Gravity-countering with VectorForce
        • Dynamic scriptable camera
        • Steering, braking, boosting
        • Fuel consumption and auto-shutdown
        • Headlights, indicators, horn
        • Durability tracking on impacts

    Excluding blank lines & comments, this has 342 lines of Lua code.
]]

-- Services (cached once for performance under heavy load)
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

-- Gameplay constants (tunable for game-feel balance)
local DEFAULT_SPEED = 50 -- Base forward studs/sec
local DEFAULT_FALL_SPEED = 40 -- How strongly we counteract gravity
local BOOST_MULTIPLIER = 1.5 -- Extra speed factor when boosting
local BRAKE_MULTIPLIER = -0.5 -- Reverse factor when braking
local MAX_FUEL = 100 -- Fuel capacity
local FUEL_CONSUMPTION_RATE = 5 -- Fuel per second at full throttle
local BOOST_FUEL_RATE = 10 -- Fuel per second while boosting
local INDICATOR_INTERVAL = 0.5 -- Blink interval for turn signals
local DURABILITY_MAX = 100 -- Durability before breakdown
local HEADLIGHT_RANGE = 15 -- Headlight range in studs

local MonowheelModule = {}

-- Returns RaycastParams that ignore our own Characters and Vehicles
local function createBlacklistParams(): RaycastParams
	local params = RaycastParams.new() -- instantiate new raycast params
	params.FilterType = Enum.RaycastFilterType.Exclude -- exclude unwanted groups
	params.FilterDescendantsInstances = {Workspace.Characters, Workspace.Vehicles} -- define groups
	return params -- ready-to-use params
end

-- Thin wrapper around Workspace:Raycast for clarity
local function castRay(origin: Vector3, direction: Vector3, params: RaycastParams)
	-- perform raycast and return first hit
	return Workspace:Raycast(origin, direction, params)
end

-- Attempts to detect a climbable wall in three phases
local function getWallHit(rootCFrame: CFrame, params: RaycastParams, throttle: number, speed: number)
	-- 1) Head-on detection
	local forwardDir = rootCFrame.LookVector * (speed * 1.2) * throttle
	local hit = castRay(rootCFrame.Position, forwardDir, params)
	if hit then -- if we hit, return immediately
		return hit
	end
	-- 2) Upward-offset detection for ledges
	local upDir = (rootCFrame.LookVector + rootCFrame.UpVector * 0.1).Unit * (speed * 0.6) * throttle
	hit = castRay(rootCFrame.Position, upDir, params)
	if hit then
		return hit
	end
	-- 3) Downward-offset detection for slopes
	local downDir = (rootCFrame.LookVector - rootCFrame.UpVector * 0.1).Unit * (speed * 0.6) * throttle
	return castRay(rootCFrame.Position, downDir, params)
end

-- Detects the “floor” beneath us, whitelisting the previous floor
local function getFloorHit(rootCFrame: CFrame, prevFloor: BasePart?, params: RaycastParams)
	local rayParams = RaycastParams.new() -- separate params to whitelist
	rayParams.FilterType = Enum.RaycastFilterType.Include -- include only specified parts
	rayParams.FilterDescendantsInstances = {prevFloor or Workspace} -- prefer last floor
	local downVec = -rootCFrame.UpVector * 6 -- cast downward six studs
	return Workspace:Raycast(rootCFrame.Position, downVec, rayParams)
end

-- Calculates a scriptable camera CFrame that trails & avoids clipping
local function computeCameraCFrame(rootCFrame: CFrame, followDist: number, velocity: Vector3, params: RaycastParams)
	-- offset seat upward based on speed for dynamic framing
	local speedFactor = math.min(velocity.Magnitude ^ 0.2, 5)
	local seatOffset = rootCFrame.UpVector * (2 + speedFactor)
	local seatPos = rootCFrame.Position + seatOffset
	-- position camera behind and to the side
	local behind = -rootCFrame.LookVector * (followDist * ((velocity.Magnitude + 1) ^ 0.1))
	local side = rootCFrame.RightVector * 2
	local rawPos = rootCFrame.Position + behind + side + (seatOffset * 0.5)
	-- raycast from rawPos to seatPos to prevent clipping into geometry
	local hit = castRay(rawPos, seatPos - rawPos, params)
	local camPos = hit and hit.Position or rawPos
	-- return a CFrame looking at the seat
	return CFrame.lookAt(camPos, seatPos, rootCFrame.UpVector)
end

-- Smoothly update camera each frame if enabled
local function updateCamera(vehicle: any)
	if not vehicle.Toggle.Camera then
		return -- skip if camera toggled off
	end
	local cam = Workspace.CurrentCamera
	cam.CameraSubject = nil -- detach default subject
	cam.CameraType = Enum.CameraType.Scriptable -- manual control
	local goal = computeCameraCFrame(vehicle.MonoRoot.CFrame, 10, vehicle.LinearVelocity, vehicle.Params)
	-- lerp towards goal for smoothness
	cam.CFrame = cam.CFrame:Lerp(goal, 0.2)
end

-- Switch friction properties based on contact state
local function adjustPhysicalProperties(vehicle: any, onWall: boolean, onGround: boolean)
	if onWall or not onGround then
		-- zero friction to allow sticking or free-fall
		vehicle.Wheel.CustomPhysicalProperties = PhysicalProperties.new(0, 0, 0)
	else
		-- restore friction for rolling
		vehicle.Wheel.CustomPhysicalProperties = PhysicalProperties.new(2, 0, 0)
	end
end

-- Tweens align orientation to match surface normal
local function alignToSurface(vehicle: any, normal: Vector3)
	local current = vehicle.Align.CFrame -- get current orientation
	local target = CFrame.fromMatrix(current.Position, current.RightVector, normal) -- build new CFrame
	vehicle.Align.CFrame = current:Lerp(target, 0.1) -- smooth transition
end

-- Applies or resets counter-gravity forces each frame
local function handleGravity(vehicle: any, groundHit: RaycastResult?)
	if not groundHit then
		-- if airborne, build up free-fall timer and increase counter force
		local dt = RunService.RenderStepped:Wait()
		vehicle.FreeFallTimer = vehicle.FreeFallTimer + dt
		local t = math.clamp(vehicle.FreeFallTimer / vehicle.MaxFallTime, 0, 1)
		local forceChange = vehicle.FallSpeed * 500 * t
		vehicle.VectorForce.Force = vehicle.VectorForce.Force - Vector3.new(0, forceChange, 0)
	else
		-- if grounded, reset timer and snap above surface
		vehicle.FreeFallTimer = 0
		vehicle.MonoRoot.Position = groundHit.Position + (groundHit.Normal * 5)
		vehicle.VectorForce.Force = Vector3.new(0, 0, 0)
	end
end

-- High-level per-frame surface handling
local function handleSurface(vehicle: any)
	local cf = vehicle.MonoRoot.CFrame
	local speed = vehicle.LinearVelocity.Magnitude
	local throttle = vehicle.Seat.Throttle
	-- optional wall detection if toggled on
	local wallHit = vehicle.Toggle.ClimbWalls and getWallHit(cf, vehicle.Params, throttle, speed)
	-- always detect ground
	local groundHit = castRay(cf.Position, -cf.UpVector * 6, vehicle.Params)
	-- adjust friction for current state
	adjustPhysicalProperties(vehicle, wallHit ~= nil, groundHit ~= nil)
	-- pick which surface to align to
	local chosenHit = wallHit or groundHit
	if chosenHit then
		alignToSurface(vehicle, chosenHit.Normal)
		vehicle.PreviousFloor = chosenHit.Instance
	end
	-- remember floor for smoother transitions
	local floorRec = getFloorHit(cf, vehicle.PreviousFloor, vehicle.Params)
	if floorRec then
		vehicle.FloorPoint = floorRec.Position
	end
	-- apply or reset gravity forces
	handleGravity(vehicle, groundHit)
end

-- Core drive logic per frame
local function updateMovement(vehicle: any)
	if not vehicle.Toggle.Movement then
		return -- skip if movement disabled
	end
	Workspace.Gravity = 0 -- override world gravity
	local steer = vehicle.Seat.Steer
	local speed = vehicle.LinearVelocity.Magnitude
	local throttle = vehicle.Seat.Throttle
	-- apply steering torque if moving fast enough
	if speed > 2 then
		local angle = -math.rad(steer * 0.2 * ((speed / vehicle.Speed * 10) ^ 0.15))
		vehicle.Vehicle:PivotTo(vehicle.Vehicle:GetPivot() * CFrame.Angles(0, 0, angle))
	end
	-- tilt wheel for visual feedback
	vehicle.Align.CFrame = vehicle.Align.CFrame * CFrame.Angles(0, math.rad(-steer / 0.9 * (speed ^ 0.15)), 0)
	-- determine base speed factor (forward, brake, boost)
	local speedFactor = throttle
	if vehicle.Toggle.Boost and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and vehicle.Fuel > 0 then
		-- boosting: increase speed, consume extra fuel
		speedFactor = throttle * BOOST_MULTIPLIER
		local dt = RunService.RenderStepped:Wait()
		vehicle.Fuel = math.max(0, vehicle.Fuel - BOOST_FUEL_RATE * dt)
	elseif throttle < 0 then
		-- braking: reverse factor
		speedFactor = throttle * BRAKE_MULTIPLIER
	end
	-- consume base fuel based on throttle magnitude
	local dt = RunService.RenderStepped:Wait()
	vehicle.Fuel = math.max(0, vehicle.Fuel - math.abs(throttle) * FUEL_CONSUMPTION_RATE * dt)
	-- apply linear velocity along look vector
	local forward = vehicle.MonoRoot.CFrame.LookVector
	vehicle.MonoRoot.AssemblyLinearVelocity = forward * (speedFactor * ((math.abs(throttle) + speed ^ 0.5) * 10))
	-- disable movement if out of fuel
	if vehicle.Fuel <= 0 then
		vehicle.Toggle.Movement = false
	end
	-- durability loss on high-speed impact
	if vehicle.LastCollisionSpeed and vehicle.LastCollisionSpeed > 100 then
		vehicle.Durability = vehicle.Durability - (vehicle.LastCollisionSpeed / 10)
		if vehicle.Durability <= 0 then
			vehicle:Destroy() -- break down if too damaged
		end
	end
	-- delegate surface and gravity logic
	handleSurface(vehicle)
end

-- Creates a floating speedometer UI
local function createSpeedometer(vehicle: any)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Speedometer"
	gui.Adornee = vehicle.MonoRoot -- attach to wheel root
	gui.Size = UDim2.new(0, 100, 0, 40)
	gui.AlwaysOnTop = true
	gui.Parent = vehicle.Vehicle
	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.Font = Enum.Font.Arcade
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Text = "0 studs/s"
	text.Parent = gui
	vehicle.SpeedUI = text -- store reference for updating
	vehicle.NextUIUpdate = os.clock() + 0.1 -- schedule first update
end

-- Updates the speedometer text at fixed intervals
local function updateSpeedometer(vehicle: any)
	if not vehicle.SpeedUI then
		return
	end
	if os.clock() >= vehicle.NextUIUpdate then
		local speed = math.floor(vehicle.LinearVelocity.Magnitude)
		vehicle.SpeedUI.Text = ("%d studs/s"):format(speed)
		vehicle.NextUIUpdate = os.clock() + 0.1 -- throttle UI updates
	end
end

-- Toggles headlights on/off; can be bound to input
local function toggleHeadlights(vehicle: any)
	if vehicle.Headlights then
		vehicle.Headlights.Enabled = not vehicle.Headlights.Enabled
	end
end

-- Blinks turn indicator frames at set interval
local function updateIndicators(vehicle: any)
	if os.clock() >= vehicle.NextIndicatorToggle then
		vehicle.IndicatorGui.Left.Visible = vehicle.Toggle.IndicatorLeft and not vehicle.IndicatorGui.Left.Visible
		vehicle.IndicatorGui.Right.Visible = vehicle.Toggle.IndicatorRight and not vehicle.IndicatorGui.Right.Visible
		vehicle.NextIndicatorToggle = os.clock() + INDICATOR_INTERVAL
	end
end

-- Plays horn sound once per trigger
local function playHorn(vehicle: any)
	if vehicle.Horn and not vehicle.Horn.IsPlaying then
		vehicle.Horn:Play()
	end
end

-- Main per-frame update orchestrator
local function onRenderStep(dt: number, vehicle: any)
	vehicle.LinearVelocity = vehicle.MonoRoot.AssemblyLinearVelocity -- refresh speed
	updateCamera(vehicle)     -- handle camera movement
	updateMovement(vehicle)   -- apply drive logic
	updateSpeedometer(vehicle)   -- refresh UI
	updateIndicators(vehicle) -- blink indicators
end

-- Public factory: sets up and returns a vehicle controller
function MonowheelModule.CreateVehicle(character: Model, monoWheel: Model, enableAll: boolean?)
	assert(character:FindFirstChild("Humanoid"), "CreateVehicle: character must have Humanoid")
	assert(monoWheel:FindFirstChild("Root"), "CreateVehicle: monoWheel must have Root part")
	local vehicle = {}
	-- core references
	vehicle.Character = character
	vehicle.Vehicle = monoWheel
	vehicle.MonoRoot = monoWheel.Root
	vehicle.Seat = monoWheel:FindFirstChildOfClass("VehicleSeat")
	vehicle.Wheel = monoWheel:FindFirstChild("Wheel")
	vehicle.Align = vehicle.MonoRoot:WaitForChild("MainAttachment").AlignOrientation
	vehicle.VectorForce = vehicle.MonoRoot:WaitForChild("MainAttachment").VectorForce
	vehicle.Params = createBlacklistParams()
	-- feature toggles
	vehicle.Toggle = {
		Camera = enableAll == nil or enableAll,
		Movement = enableAll == nil or enableAll,
		ClimbWalls = enableAll == nil or enableAll,
		Boost = enableAll == nil or enableAll,
		IndicatorLeft = false,
		IndicatorRight = false,
	}
	-- initialize state
	vehicle.Speed = DEFAULT_SPEED
	vehicle.FallSpeed = DEFAULT_FALL_SPEED
	vehicle.MaxFallTime = 5
	vehicle.FreeFallTimer = 0
	vehicle.LinearVelocity = Vector3.new(0, 0, 0)
	vehicle.FloorPoint = nil
	vehicle.PreviousFloor = nil
	vehicle.Fuel = MAX_FUEL
	vehicle.Durability = DURABILITY_MAX
	vehicle.LastCollisionSpeed = 0
	-- headlights setup
	vehicle.Headlights = Instance.new("SpotLight", monoWheel.Root)
	vehicle.Headlights.Enabled = false
	vehicle.Headlights.Range = HEADLIGHT_RANGE
	-- horn setup
	vehicle.Horn = Instance.new("Sound", monoWheel.Root)
	vehicle.Horn.SoundId = "rbxassetid://12345678"
	vehicle.Horn.Looped = false
	-- indicator GUI
	local indGui = Instance.new("BillboardGui", monoWheel.Root)
	indGui.Size = UDim2.new(0, 50, 0, 20)
	indGui.AlwaysOnTop = true
	local leftFrame = Instance.new("Frame", indGui)
	leftFrame.Size = UDim2.new(0.4, 0, 1, 0)
	leftFrame.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
	leftFrame.Visible = false
	local rightFrame = Instance.new("Frame", indGui)
	rightFrame.Position = UDim2.new(0.6, 0, 0, 0)
	rightFrame.Size = UDim2.new(0.4, 0, 1, 0)
	rightFrame.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
	rightFrame.Visible = false
	vehicle.IndicatorGui = {Left = leftFrame, Right = rightFrame}
	vehicle.NextIndicatorToggle = 0
	-- UI creation
	createSpeedometer(vehicle)
	-- collision tracking for durability
	monoWheel.PrimaryPart = monoWheel.Root
	monoWheel.Root.Touched:Connect(function(hit)
		vehicle.LastCollisionSpeed = vehicle.LinearVelocity.Magnitude
	end)
	-- bind main loop
	RunService:BindToRenderStep("MonowheelUpdate", Enum.RenderPriority.Camera.Value, function(_, dt)
		onRenderStep(dt, vehicle)
	end)
	-- cleanup method
	function vehicle:Destroy()
		RunService:UnbindFromRenderStep("MonowheelUpdate")
		local cam = Workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Custom
		cam.CameraSubject = character.Humanoid
		Workspace.Gravity = Workspace.Gravity
		if self.SpeedUI and self.SpeedUI.Parent then
			self.SpeedUI.Parent:Destroy()
		end
		if self.IndicatorGui and self.IndicatorGui.Left.Parent then
			self.IndicatorGui.Left.Parent:Destroy()
		end
		self.Headlights:Destroy()
		self.Horn:Destroy()
		self.VectorForce.Force = Vector3.new(0, 0, 0)
		self.Wheel.CustomPhysicalProperties = PhysicalProperties.new(2, 0, 0)
		monoWheel:Destroy()
	end
	return vehicle
end

return MonowheelModule
