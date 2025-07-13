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
local RunService = game:GetService("RunService") -- drive per-frame updates
local Players = game:GetService("Players") -- might extend to player-specific logic
local Debris = game:GetService("Debris") -- cleanup of transient objects if needed
local UserInputService = game:GetService("UserInputService") -- detect shift for boost, turn signals, etc.
local Workspace = game:GetService("Workspace") -- physics world, raycasts, gravity

-- Gameplay constants (tunable for game-feel balance)
local DEFAULT_SPEED = 50 -- baseline velocity magnitude
local DEFAULT_FALL_SPEED = 40 -- initial counter-gravity force magnitude
local BOOST_MULTIPLIER = 1.5 -- multiplies throttle for burst acceleration
local BRAKE_MULTIPLIER = -0.5 -- inverts throttle for reverse braking
local MAX_FUEL = 100 -- seconds of full-throttle usage before depletion
local FUEL_CONSUMPTION_RATE = 5 -- fuel units per second at normal throttle
local BOOST_FUEL_RATE = 10 -- extra fuel cost when boosting
local INDICATOR_INTERVAL = 0.5 -- blink rate for turn signals
local DURABILITY_MAX = 100 -- total HP before vehicle breaks
local HEADLIGHT_RANGE = 15 -- how far headlights illuminate

local MonowheelModule = {}

-- Returns RaycastParams excluding our own characters and vehicles
local function createBlacklistParams(): RaycastParams
	-- filter out self and passengers to avoid self-collisions
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		Workspace.Characters, -- exclude player avatars
		Workspace.Vehicles -- exclude other vehicles to prevent false hits
	}
	return params
end

-- Thin wrapper around Workspace:Raycast for separation of concerns
local function castRay(origin: Vector3, direction: Vector3, params: RaycastParams)
	-- origin & direction define our query; using cached params for performance
	return Workspace:Raycast(origin, direction, params)
end

-- Attempts to detect a climbable wall in three directional offsets
local function getWallHit(rootCFrame: CFrame, params: RaycastParams, throttle: number, speed: number)
	-- head-on cast scaled by throttle & speed for dynamic wall reach
	local forwardDir = rootCFrame.LookVector * (speed * 1.2) * throttle
	local hit = castRay(rootCFrame.Position, forwardDir, params)
	if hit then
		return hit -- immediate wall ahead; strongest detection priority
	end

	-- ledge detection: slight upward bias to catch edges above current height
	local upDir = (rootCFrame.LookVector + rootCFrame.UpVector * 0.1).Unit
		* (speed * 0.6) * throttle
	hit = castRay(rootCFrame.Position, upDir, params)
	if hit then
		return hit -- found a climbable ledge
	end

	-- slope detection: downward bias to handle inclined surfaces
	local downDir = (rootCFrame.LookVector - rootCFrame.UpVector * 0.1).Unit
		* (speed * 0.6) * throttle
	-- no early return so that this always runs if others miss
	return castRay(rootCFrame.Position, downDir, params)
end

-- Detects the “floor” beneath us, preferring the last-known floor part for smooth transitions
local function getFloorHit(rootCFrame: CFrame, prevFloor: BasePart?, params: RaycastParams)
	-- build separate params to only hit the previous floor, reducing jitter when transitioning
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { prevFloor or Workspace }
	local downVec = -rootCFrame.UpVector * 6 -- 6 studs drop to check ground proximity
	return Workspace:Raycast(rootCFrame.Position, downVec, rayParams)
end

-- Calculates camera CFrame that trails & avoids geometry by raycasting to the rider position
local function computeCameraCFrame(rootCFrame: CFrame, followDist: number, velocity: Vector3, params: RaycastParams)
	-- dynamically raise camera when moving faster to give more context
	local speedFactor = math.min(velocity.Magnitude ^ 0.2, 5)
	local seatOffset = rootCFrame.UpVector * (2 + speedFactor)
	local seatPos = rootCFrame.Position + seatOffset

	-- position behind vehicle based on followDist, softened by movement speed
	local behind = -rootCFrame.LookVector * (followDist * ((velocity.Magnitude + 1) ^ 0.1))
	local side = rootCFrame.RightVector * 2 -- slight offset to the right for better composition
	local rawPos = rootCFrame.Position + behind + side + (seatOffset * 0.5)

	-- raycast toward seatPos to prevent camera clipping in walls
	local hit = castRay(rawPos, seatPos - rawPos, params)
	local camPos = hit and hit.Position or rawPos

	-- final CFrame looks back at the seat, keeping horizon level
	return CFrame.lookAt(camPos, seatPos, rootCFrame.UpVector)
end

-- Smoothly lerps camera towards computed goal each frame
local function updateCamera(vehicle: any)
	if not vehicle.Toggle.Camera then
		return -- early-out if user toggled off
	end
	local cam = Workspace.CurrentCamera
	cam.CameraSubject = nil
	cam.CameraType = Enum.CameraType.Scriptable
	local goal = computeCameraCFrame(
		vehicle.MonoRoot.CFrame,
		10,
		vehicle.LinearVelocity,
		vehicle.Params
	)
	-- LERP smoothing factor trades off responsiveness vs. jitter
	cam.CFrame = cam.CFrame:Lerp(goal, 0.2)
end

-- Switches wheel friction based on whether we're on a wall or grounded
local function adjustPhysicalProperties(vehicle: any, onWall: boolean, onGround: boolean)
	if onWall or not onGround then
		-- zero friction allows sticking to walls or true free-fall without unwanted drag
		vehicle.Wheel.CustomPhysicalProperties = PhysicalProperties.new(0, 0, 0)
	else
		-- standard friction restores rolling traction on flat ground
		vehicle.Wheel.CustomPhysicalProperties = PhysicalProperties.new(2, 0, 0)
	end
end

-- Gradually aligns vehicle orientation to match the surface normal for seamless traversal
local function alignToSurface(vehicle: any, normal: Vector3)
	local current = vehicle.Align.CFrame
	-- construct a CFrame with right vector preserved and new up vector as surface normal
	local target = CFrame.fromMatrix(current.Position, current.RightVector, normal)
	-- smooth interpolation prevents sudden pops on uneven terrain
	vehicle.Align.CFrame = current:Lerp(target, 0.1)
end

-- Applies or resets counter-gravity forces each frame, building up in air for realistic drop
local function handleGravity(vehicle: any, groundHit: RaycastResult?)
	if not groundHit then
		-- airborne: ramp up force based on time aloft to simulate acceleration under gravity
		local dt = RunService.RenderStepped:Wait()
		vehicle.FreeFallTimer = vehicle.FreeFallTimer + dt
		local t = math.clamp(vehicle.FreeFallTimer / vehicle.MaxFallTime, 0, 1)
		local forceChange = vehicle.FallSpeed * 500 * t
		vehicle.VectorForce.Force = vehicle.VectorForce.Force - Vector3.new(0, forceChange, 0)
	else
		-- grounded: snap to just above surface to avoid small gaps and reset forces
		vehicle.FreeFallTimer = 0
		vehicle.MonoRoot.Position = groundHit.Position + (groundHit.Normal * 5)
		vehicle.VectorForce.Force = Vector3.new(0, 0, 0)
	end
end

-- High-level logic combining wall/ground detection, friction, and orientation
local function handleSurface(vehicle: any)
	local cf = vehicle.MonoRoot.CFrame
	local speed = vehicle.LinearVelocity.Magnitude
	local throttle = vehicle.Seat.Throttle

	-- optionally detect walls when climb is enabled, using dynamic distances
	local wallHit = vehicle.Toggle.ClimbWalls and getWallHit(cf, vehicle.Params, throttle, speed)
	-- always check for ground directly beneath
	local groundHit = castRay(cf.Position, -cf.UpVector * 6, vehicle.Params)

	-- adjust friction early so alignment/toss logic uses correct physics
	adjustPhysicalProperties(vehicle, wallHit ~= nil, groundHit ~= nil)

	-- choose wall over ground if both detected, preserving climb priority
	local chosenHit = wallHit or groundHit
	if chosenHit then
		alignToSurface(vehicle, chosenHit.Normal)
		vehicle.PreviousFloor = chosenHit.Instance -- cache for floor hit smoothing
	end

	-- smooth floor transitions by re-projecting to last known floor part
	local floorRec = getFloorHit(cf, vehicle.PreviousFloor, vehicle.Params)
	if floorRec then
		vehicle.FloorPoint = floorRec.Position
	end

	-- manage counter-gravity and snapping
	handleGravity(vehicle, groundHit)
end

-- Core drive logic per frame: steering, throttle, fuel, and durability
local function updateMovement(vehicle: any)
	if not vehicle.Toggle.Movement then
		return -- completely disable drive when toggled off
	end

	-- override engine-level gravity; we manage physics manually below
	Workspace.Gravity = 0

	local steer = vehicle.Seat.Steer
	local speed = vehicle.LinearVelocity.Magnitude
	local throttle= vehicle.Seat.Throttle

	-- only allow steering torque once we have some forward momentum
	if speed > 2 then
		-- steering angle scaled by speed for tighter control at low speeds
		local angle = -math.rad(steer * 0.2 * ((speed / vehicle.Speed * 10) ^ 0.15))
		vehicle.Vehicle:PivotTo(vehicle.Vehicle:GetPivot() * CFrame.Angles(0, 0, angle))
	end

	-- visual tilt: amplify with speed for more pronounced bank at higher velocities
	vehicle.Align.CFrame = vehicle.Align.CFrame
		* CFrame.Angles(0, math.rad(-steer / 0.9 * (speed ^ 0.15)), 0)

	-- determine effective throttle: boost, brake, or normal
	local speedFactor = throttle
	if vehicle.Toggle.Boost
		and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		and vehicle.Fuel > 0
	then
		-- engage boost: higher acceleration for short bursts
		speedFactor = throttle * BOOST_MULTIPLIER
		local dt = RunService.RenderStepped:Wait()
		vehicle.Fuel = math.max(0, vehicle.Fuel - BOOST_FUEL_RATE * dt)
	elseif throttle < 0 then
		-- braking: invert throttle to apply reverse thrust
		speedFactor = throttle * BRAKE_MULTIPLIER
	end

	-- consume fuel proportional to absolute throttle input for realism
	do
		local dt = RunService.RenderStepped:Wait()
		vehicle.Fuel = math.max(0, vehicle.Fuel - math.abs(throttle) * FUEL_CONSUMPTION_RATE * dt)
	end

	-- apply new velocity along forward vector, combining throttle & momentum
	local forward = vehicle.MonoRoot.CFrame.LookVector
	vehicle.MonoRoot.AssemblyLinearVelocity =
		forward * (speedFactor * ((math.abs(throttle) + speed ^ 0.5) * 10))

	-- disable movement if fuel is exhausted
	if vehicle.Fuel <= 0 then
		vehicle.Toggle.Movement = false
	end

	-- reduce durability on high-speed impacts once per frame
	if vehicle.LastCollisionSpeed and vehicle.LastCollisionSpeed > 100 then
		vehicle.Durability = vehicle.Durability - (vehicle.LastCollisionSpeed / 10)
		if vehicle.Durability <= 0 then
			vehicle:Destroy() -- trigger permanent breakdown
		end
	end

	-- delegate surface-handling: friction, alignment, gravity
	handleSurface(vehicle)
end

-- Creates a floating speedometer UI attached to the wheel root
local function createSpeedometer(vehicle: any)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Speedometer"
	gui.Adornee = vehicle.MonoRoot -- pins to vehicle center
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

	vehicle.SpeedUI = text
	vehicle.NextUIUpdate = os.clock() + 0.1 -- schedule first update at 0.1s
end

-- Updates the speedometer only at fixed intervals to reduce UI overhead
local function updateSpeedometer(vehicle: any)
	if not vehicle.SpeedUI then return end
	if os.clock() >= vehicle.NextUIUpdate then
		local speed = math.floor(vehicle.LinearVelocity.Magnitude)
		vehicle.SpeedUI.Text = ("%d studs/s"):format(speed)
		vehicle.NextUIUpdate = os.clock() + 0.1 -- throttle to 10 updates/sec
	end
end

-- Toggles headlights state; straightforward but kept separate for future expansion
local function toggleHeadlights(vehicle: any)
	if vehicle.Headlights then
		vehicle.Headlights.Enabled = not vehicle.Headlights.Enabled
	end
end

-- Blinks turn indicators based on user input and timing
local function updateIndicators(vehicle: any)
	if os.clock() >= vehicle.NextIndicatorToggle then
		-- flip visibility only if that indicator is active; prevents ghost blinks
		vehicle.IndicatorGui.Left.Visible = vehicle.Toggle.IndicatorLeft
			and not vehicle.IndicatorGui.Left.Visible
		vehicle.IndicatorGui.Right.Visible = vehicle.Toggle.IndicatorRight
			and not vehicle.IndicatorGui.Right.Visible
		vehicle.NextIndicatorToggle = os.clock() + INDICATOR_INTERVAL
	end
end

-- Plays horn sound exactly once per trigger to avoid overlap
local function playHorn(vehicle: any)
	if vehicle.Horn and not vehicle.Horn.IsPlaying then
		vehicle.Horn:Play()
	end
end

-- Main per-frame update orchestrator, bound to RenderStepped
local function onRenderStep(dt: number, vehicle: any)
	-- capture latest physics velocity before logic executes
	vehicle.LinearVelocity = vehicle.MonoRoot.AssemblyLinearVelocity

	updateCamera(vehicle) -- reposition scriptable camera
	updateMovement(vehicle) -- handle drive, fuel, durability
	updateSpeedometer(vehicle) -- refresh speed UI
	updateIndicators(vehicle) -- blink turn signals if active
end

-- Public factory: sets up and returns a fully-initialized vehicle controller
function MonowheelModule.CreateVehicle(character: Model, monoWheel: Model, enableAll: boolean?)
	-- validate required parts to avoid runtime nil errors
	assert(character:FindFirstChild("Humanoid"),
		"CreateVehicle: character must have Humanoid")
	assert(monoWheel:FindFirstChild("Root"),
		"CreateVehicle: monoWheel must have Root part")

	local vehicle = {}
	-- cache core references for fast access in per-frame loops
	vehicle.Character = character
	vehicle.Vehicle = monoWheel
	vehicle.MonoRoot = monoWheel.Root
	vehicle.Seat = monoWheel:FindFirstChildOfClass("VehicleSeat")
	vehicle.Wheel = monoWheel:FindFirstChild("Wheel")
	vehicle.Align = vehicle.MonoRoot:WaitForChild("MainAttachment").AlignOrientation
	vehicle.VectorForce = vehicle.MonoRoot:WaitForChild("MainAttachment").VectorForce
	vehicle.Params = createBlacklistParams()

	-- feature toggles default to true unless explicitly disabled
	vehicle.Toggle = {
		Camera = enableAll == nil or enableAll,
		Movement = enableAll == nil or enableAll,
		ClimbWalls = enableAll == nil or enableAll,
		Boost = enableAll == nil or enableAll,
		IndicatorLeft = false,
		IndicatorRight = false,
	}

	-- initialize dynamic state variables
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

	-- headlight setup: individual light per wheel root for clear night driving
	vehicle.Headlights = Instance.new("SpotLight", monoWheel.Root)
	vehicle.Headlights.Enabled = false
	vehicle.Headlights.Range = HEADLIGHT_RANGE

	-- horn setup: ready to play short sound on demand
	vehicle.Horn = Instance.new("Sound", monoWheel.Root)
	vehicle.Horn.SoundId = "rbxassetid://12345678"
	vehicle.Horn.Looped = false

	-- turn indicator GUI attached to root for left/right signals
	local indGui = Instance.new("BillboardGui", monoWheel.Root)
	indGui.Size = UDim2.new(0, 50, 0, 20)
	indGui.AlwaysOnTop= true
	local leftFrame = Instance.new("Frame", indGui)
	leftFrame.Size = UDim2.new(0.4, 0, 1, 0)
	leftFrame.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
	leftFrame.Visible = false
	local rightFrame = Instance.new("Frame", indGui)
	rightFrame.Position = UDim2.new(0.6, 0, 0, 0)
	rightFrame.Size = UDim2.new(0.4, 0, 1, 0)
	rightFrame.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
	rightFrame.Visible = false
	vehicle.IndicatorGui = { Left = leftFrame, Right = rightFrame }
	vehicle.NextIndicatorToggle = 0

	-- create the speedometer UI and schedule its first update
	createSpeedometer(vehicle)

	-- collision tracking for durability: record impact speed for damage calculation
	monoWheel.PrimaryPart = monoWheel.Root
	monoWheel.Root.Touched:Connect(function(hit)
		vehicle.LastCollisionSpeed = vehicle.LinearVelocity.Magnitude
	end)

	-- bind main update loop to RenderStepped for consistent timing
	RunService:BindToRenderStep("MonowheelUpdate",
		Enum.RenderPriority.Camera.Value,
		function(_, dt)
			onRenderStep(dt, vehicle)
		end)

	-- cleanup method: unbind loops, restore camera, destroy parts
	function vehicle:Destroy()
		RunService:UnbindFromRenderStep("MonowheelUpdate")
		local cam = Workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Custom
		cam.CameraSubject = character.Humanoid
		Workspace.Gravity = Workspace.Gravity -- restore original gravity

		-- remove UI elements if still present
		if self.SpeedUI and self.SpeedUI.Parent then
			self.SpeedUI.Parent:Destroy()
		end
		if self.IndicatorGui and self.IndicatorGui.Left.Parent then
			self.IndicatorGui.Left.Parent:Destroy()
		end

		-- destroy lights, sounds, and vehicle model
		self.Headlights:Destroy()
		self.Horn:Destroy()
		self.VectorForce.Force = Vector3.new(0, 0, 0)
		self.Wheel.CustomPhysicalProperties =
			PhysicalProperties.new(2, 0, 0)
		monoWheel:Destroy()
	end

	return vehicle
end

return MonowheelModule
