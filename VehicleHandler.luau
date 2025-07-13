--!strict
--[[
    Monowheel Vehicle Control Script
    Author: Jinga
    Description: Single-wheel vehicle capable of wall-climbing, gravity countering, 
    and dynamic camera control. Script placed under a Seat instance.
--]]

-- Services
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

-- Constants
local DEFAULT_SPEED = 50 -- Base speed for the wheel
local DEFAULT_FALL_SPEED = 40 -- Base fall speed multiplier
local CAMERA_PRIORITY = Enum.RenderPriority.Camera.Value -- Priority for camera binding
local SPEEDOMETER_UPDATE_RATE = 0.1 -- Seconds between UI updates

-- Module table
local MonowheelModule = {}

-- Utility: Error handling wrapper
local function safeExecute(fn: () -> ())
	-- Wrap in pcall and warn errors with line number
	local success, err = pcall(fn)
	if not success then
		warn("[Monowheel] Error at line " .. tostring($line) .. ": " .. tostring(err))
	end
end

-- Utility: Create RaycastParams blacklist filter
local function createBlacklistParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist
	params.FilterDescendantsInstances = {workspace.Characters, workspace.Vehicles}
	return params
end


-- Cast a ray from origin, direction, using provided params
local function castRay(origin: Vector3, direction: Vector3, params: RaycastParams)
	return workspace:Raycast(origin, direction, params)
end

-- Get wall hits for surface detection
local function getWallHit(cframe: CFrame, params: RaycastParams, throttle: number, speed: number)
	-- Try multiple ray directions
	local function tryDir(vecKey: string, mul: number, dist: number)
		local dirVec = (cframe.LookVector - (cframe[vecKey] * mul)).Unit * dist * throttle
		return castRay(cframe.Position, dirVec, params)
	end
	return tryDir("LookVector", 0, speed * 1.2)
		or tryDir("UpVector", 0.1, speed / 10)
		or tryDir("UpVector", -0.9, speed / 10)
end

-- Get floor hit for gravity counter
local function getFloorHit(cframe: CFrame, prevFloor: Instance?, params: RaycastParams)
	-- Whitelist previous floor for closest point
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Whitelist
	rayParams.FilterDescendantsInstances = {prevFloor or workspace}
	local dir = (prevFloor and prevFloor.Position or (cframe.Position - Vector3.new(0,6))) - cframe.Position
	return castRay(cframe.Position, dir, rayParams)
end


-- Compute new camera CFrame based on vehicle
local function computeCameraCFrame(rootCFrame: CFrame, range: number, velocity: Vector3, params: RaycastParams)
	local seatPos = rootCFrame.Position + (rootCFrame.UpVector * (2 + math.min(velocity.Magnitude ^ 0.2, 5)))
	local camPos = rootCFrame.Position
		+ ((-rootCFrame.LookVector * (math.floor(velocity.Magnitude + 1) ^ 0.1) + rootCFrame.UpVector / 2) * range)
		+ rootCFrame.RightVector * 2
	local wallHit = castRay(camPos, (rootCFrame.Position - camPos), params)
	local focus = wallHit and wallHit.Position or camPos
	return CFrame.lookAt(focus, seatPos, rootCFrame.UpVector)
end

-- Smoothly update the camera each frame
local function updateCamera(vehicle: any)
	if not vehicle.Toggle.Camera then return end
	local cam = workspace.CurrentCamera
	cam.CameraSubject = nil
	cam.CameraType = Enum.CameraType.Scriptable
	local newCFrame = computeCameraCFrame(
		vehicle.MonoRoot.CFrame,
		10,
		vehicle.LinearVelocity,
		vehicle.Params
	)
	cam.CFrame = cam.CFrame:Lerp(newCFrame, 0.2)
end

-- Handle surface orientation and gravity
local function handleSurface(vehicle: any)
	local cframe = vehicle.MonoRoot.CFrame
	local velocity = vehicle.LinearVelocity.Magnitude
	local throttle = vehicle.Seat.Throttle
	local hitWall = nil
	if vehicle.Toggle.ClimbWalls then
		hitWall = getWallHit(cframe, vehicle.Params, throttle, velocity)
	end
	-- Detect floor
	local floorHit = castRay(cframe.Position, -cframe.UpVector * 6, vehicle.Params)

	-- Adjust wheel physics
	if hitWall or not floorHit then
		vehicle.Wheel.CustomPhysicalProperties = PhysicalProperties.new(0, 0, 0)
	else
		vehicle.Wheel.CustomPhysicalProperties = PhysicalProperties.new(2, 0, 0)
	end

	-- Compute floor point for aligning orientation
	vehicle.PreviousFloor = hitWall and hitWall.Instance or (floorHit and floorHit.Instance) or vehicle.PreviousFloor
	local nearest = getFloorHit(cframe, vehicle.PreviousFloor, vehicle.Params)
	if nearest then
		vehicle.FloorPoint = nearest.Position
	end

	-- Tween orientation to match surface normal
	if vehicle.FloorPoint then
		local normal = nearest and nearest.Normal or Vector3.new(0, 1, 0)
		vehicle.Align.CFrame = vehicle.Align.CFrame:Lerp(
			CFrame.fromMatrix(
				vehicle.Align.CFrame.Position,
				vehicle.Align.CFrame.RightVector,
				normal
			),
			0.1
		)
	end

	-- Gravity control
	if not floorHit then
		vehicle.FreeFallTimer = vehicle.FreeFallTimer + RunService.RenderStepped:Wait()
		local fallPercent = math.clamp(vehicle.FreeFallTimer / vehicle.MaxFallTime, 0, 1)
		vehicle.VectorForce.Force = vehicle.VectorForce.Force - Vector3.new(0, vehicle.FallSpeed * 500 * fallPercent, 0)
	else
		vehicle.FreeFallTimer = 0
		vehicle.MonoRoot.Position = floorHit.Position + (floorHit.Normal * 5)
		vehicle.VectorForce.Force = Vector3.new(0, 0, 0)
	end
end

-- Update movement each frame
local function updateMovement(vehicle: any)
	if not vehicle.Toggle.Movement then return end
	workspace.Gravity = 0
	
	-- Steering and throttle
	local steer = vehicle.Seat.Steer
	local vel = vehicle.LinearVelocity.Magnitude
	if vel > 2 then
		safeExecute(function()
			vehicle.Vehicle:PivotTo(
				vehicle.Vehicle:GetPivot() * CFrame.Angles(
					0, 0,
					-math.rad(steer * 0.2 * ((vel / vehicle.Speed * 10) ^ 0.15))
				)
			)
		end)
	end
	-- Rotate root based on steering and velocity
	vehicle.Align.CFrame *= CFrame.Angles(0, math.rad(-steer / 0.9 * (vel ^ 0.15)), 0)
	-- Apply forward force
	vehicle.MonoRoot.AssemblyLinearVelocity = vehicle.MonoRoot.CFrame.LookVector * (vehicle.Seat.Throttle * ((math.abs(vehicle.Seat.Throttle) + vel ^ 0.5) * 10))

	-- Surface and gravity handling
	handleSurface(vehicle)
end


-- Create a BillboardGui speedometer above the wheel
local function createSpeedometer(vehicle: any)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Speedometer"
	gui.Size = UDim2.new(0, 100, 0, 40)
	gui.Adornee = vehicle.MonoRoot
	gui.AlwaysOnTop = true
	gui.Parent = vehicle.Vehicle

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Font = Enum.Font.Arcade
	text.Text = "0 RPM"
	text.Parent = gui

	vehicle.SpeedUI = text
	vehicle.NextUIUpdate = os.clock() + SPEEDOMETER_UPDATE_RATE
end

-- Update speedometer text
local function updateSpeedometer(vehicle: any)
	if not vehicle.SpeedUI then return end
	if os.clock() >= vehicle.NextUIUpdate then
		local speed = math.floor(vehicle.LinearVelocity.Magnitude)
		vehicle.SpeedUI.Text = tostring(speed) .. " studs/s"
		vehicle.NextUIUpdate = os.clock() + SPEEDOMETER_UPDATE_RATE
	end
end


-- Bound to RenderStep for continuous updates
local function onRenderStep(name: string, dt: number, vehicle: any)
	safeExecute(function()
		-- Refresh data
		vehicle.LinearVelocity = vehicle.MonoRoot.AssemblyLinearVelocity
		-- Camera
		updateCamera(vehicle)
		-- Movement
		updateMovement(vehicle)
		-- UI
		updateSpeedometer(vehicle)
	end)
end


-- creates the vehicle object and sets up events
function MonowheelModule.CreateVehicle(character: Model, monoWheel: Model, toggle: boolean?)
	-- Validate inputs
	assert(character and character:FindFirstChild("Humanoid"), "Character with Humanoid required")
	assert(monoWheel and monoWheel.Root, "MonoWheel model with Root part required")

	-- Vehicle object
	local vehicle = {}
	vehicle.Character = character
	vehicle.Seat = assert(monoWheel:FindFirstChildOfClass("VehicleSeat"), "VehicleSeat required")
	vehicle.Vehicle = monoWheel
	vehicle.MonoRoot = monoWheel.Root
	vehicle.Wheel = assert(monoWheel:FindFirstChild("Wheel"), "Wheel part required")
	vehicle.Align = assert(vehicle.MonoRoot:WaitForChild("MainAttachment").AlignOrientation, "AlignOrientation required")
	vehicle.VectorForce = assert(vehicle.MonoRoot:WaitForChild("MainAttachment").VectorForce, "VectorForce required")
	vehicle.Params = createBlacklistParams()
	vehicle.Toggle = {Camera = toggle == nil or toggle, Movement = toggle == nil or toggle, ClimbWalls = toggle == nil or toggle}

	-- Physics params
	vehicle.Speed = DEFAULT_SPEED
	vehicle.FallSpeed = DEFAULT_FALL_SPEED
	vehicle.MaxFallTime = 5
	vehicle.FreeFallTimer = 0

	-- Dynamic properties
	vehicle.LinearVelocity = Vector3.new(0, 0, 0)
	vehicle.FloorPoint = nil
	vehicle.PreviousFloor = nil

	-- Setup UI
	createSpeedometer(vehicle)

	-- Bind update
	RunService:BindToRenderStep("MonowheelUpdate", CAMERA_PRIORITY, function(dt)
		onRenderStep("MonowheelUpdate", dt, vehicle)
	end)

	-- Cleanup function
	function vehicle:Destroy()
		RunService:UnbindFromRenderStep("MonowheelUpdate")
		local cam = workspace.CurrentCamera
		cam.CameraSubject = character.Humanoid
		cam.CameraType = Enum.CameraType.Custom
		workspace.Gravity = game:GetService("Workspace").Gravity
		if self.SpeedUI and self.SpeedUI.Parent then
			self.SpeedUI.Parent:Destroy()
		end
		self.VectorForce.Force = Vector3.new(0, 0, 0)
		self.Wheel.CustomPhysicalProperties = PhysicalProperties.new(2, 0, 0)
		self.Vehicle:Destroy()
	end

	return vehicle
end

return MonowheelModule
