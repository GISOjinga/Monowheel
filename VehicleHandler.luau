-- this gets started on the client after my humanoid sits in the VehicleSeat
-- the place already has Root, Wheel and MainAttachment with the constraints on it
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DEFAULT_SPEED = 50
local BOOST_MULTIPLIER = 1.5
local BRAKE_MULTIPLIER = 0.5
local MAX_FUEL = 100
local FUEL_CONSUMPTION_RATE = 5
local BOOST_FUEL_RATE = 10
local INDICATOR_INTERVAL = 0.5
local DURABILITY_MAX = 100
local HEADLIGHT_RANGE = 15
local IMPACT_SPEED = 100
local IMPACT_COOLDOWN = 0.75

local MonowheelModule = {}
local nextVehicleId = 0
local activeBySeat: { [VehicleSeat]: any } = {}

local function createBlacklistParams(character: Model, monoWheel: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- dont let the rays hit my own char or wheel, other walls/vehicles still count
	params.FilterDescendantsInstances = { character, monoWheel }
	return params
end

local function castRay(origin: Vector3, direction: Vector3, params: RaycastParams)
	return Workspace:Raycast(origin, direction, params)
end

local function getWallHit(rootCFrame: CFrame, params: RaycastParams, throttle: number, speed: number)
	if throttle <= 0 then
		return nil
	end
	local reach = math.clamp(speed * 0.2, 6, 18)
	-- check strait ahead first so the angled rays dont pick a side wall instead
	local forwardDir = rootCFrame.LookVector * reach
	local hit = castRay(rootCFrame.Position, forwardDir, params)
	if hit then
		return hit
	end

	local upDir = (rootCFrame.LookVector + rootCFrame.UpVector * 0.1).Unit
		* reach
	hit = castRay(rootCFrame.Position, upDir, params)
	if hit then
		return hit
	end

	local downDir = (rootCFrame.LookVector - rootCFrame.UpVector * 0.1).Unit
		* reach
	return castRay(rootCFrame.Position, downDir, params)
end

local function computeCameraCFrame(rootCFrame: CFrame, followDist: number, velocity: Vector3, params: RaycastParams)
	-- when its moving faster i lift the camera a bit so you can see ahead
	local speedFactor = math.min(velocity.Magnitude ^ 0.2, 5)
	local seatOffset = rootCFrame.UpVector * (2 + speedFactor)
	local seatPos = rootCFrame.Position + seatOffset

	local behind = -rootCFrame.LookVector * (followDist * ((velocity.Magnitude + 1) ^ 0.1))
	local side = rootCFrame.RightVector * 2
	local rawPos = rootCFrame.Position + behind + side + (seatOffset * 0.5)

	local hit = castRay(rawPos, seatPos - rawPos, params)
	-- if theres a wall between camera and rider, stop at the hit with a little gap
	local camPos = hit and hit.Position + hit.Normal * 0.3 or rawPos

	return CFrame.lookAt(camPos, seatPos, rootCFrame.UpVector)
end

local function updateCamera(vehicle: any)
	if not vehicle.Toggle.Camera then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	-- same ignore list as the wall rays, otherwise the camera could hit my own wheel
	local goal = computeCameraCFrame(
		vehicle.MonoRoot.CFrame,
		10,
		vehicle.LinearVelocity,
		vehicle.Params
	)
	cam.CFrame = cam.CFrame:Lerp(goal, 0.2)
end

local function adjustPhysicalProperties(vehicle: any, onWall: boolean, onGround: boolean)
	local lowFriction = onWall or not onGround
	-- dont keep setting friction every frame if the wheel is still in the same state
	if vehicle.LowFriction == lowFriction then
		return
	end
	vehicle.LowFriction = lowFriction
	if lowFriction then
		vehicle.Wheel.CustomPhysicalProperties = PhysicalProperties.new(0, 0, 0)
	else
		vehicle.Wheel.CustomPhysicalProperties = vehicle.OriginalWheelProperties
	end
end

local function alignToSurface(vehicle: any, normal: Vector3)
	local current = vehicle.Align.CFrame
	local forward = vehicle.MonoRoot.CFrame.LookVector
	-- get the forward direction along the surface first or lookAt can twist into the wall
	local flatForward = forward - normal * forward:Dot(normal)
	if flatForward.Magnitude < 0.01 then
		return
	end
	local target = CFrame.lookAt(Vector3.zero, flatForward.Unit, normal)
	vehicle.Align.CFrame = current:Lerp(target, 0.1)
end

local function handleGravity(vehicle: any, wallHit: RaycastResult?)
	if wallHit then
		-- only push this wheel up, changing Workspace.Gravity would mess with everyone
		vehicle.VectorForce.Force = Vector3.yAxis * vehicle.MonoRoot.AssemblyMass * Workspace.Gravity
	else
		vehicle.VectorForce.Force = Vector3.zero
	end
end

local function handleSurface(vehicle: any)
	local cf = vehicle.MonoRoot.CFrame
	local speed = vehicle.LinearVelocity.Magnitude
	local throttle = vehicle.Seat.Throttle

	local wallHit: RaycastResult? = nil
	if vehicle.Toggle.ClimbWalls then
		wallHit = getWallHit(cf, vehicle.Params, throttle, speed)
	end
	local groundHit = castRay(cf.Position, -cf.UpVector * 6, vehicle.Params)
	vehicle.Climbing = wallHit ~= nil

	adjustPhysicalProperties(vehicle, wallHit ~= nil, groundHit ~= nil)

	-- if both rays hit i tilt to the wall and use low friction for the climb
	local chosenHit = wallHit or groundHit
	if chosenHit then
		alignToSurface(vehicle, chosenHit.Normal)
	end

	handleGravity(vehicle, wallHit)
end

local function updateMovement(vehicle: any, dt: number)
	if not vehicle.Toggle.Movement then
		return
	end

	local steer = vehicle.Seat.SteerFloat
	local throttle = vehicle.Seat.ThrottleFloat
	local boosting = vehicle.Toggle.Boost
		and throttle > 0
		and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		and vehicle.Fuel > 0
	if vehicle.Fuel <= 0 then
		throttle = 0
	end

	local speedFactor = throttle
	if boosting then
		speedFactor *= BOOST_MULTIPLIER
	elseif throttle < 0 then
		speedFactor *= BRAKE_MULTIPLIER
	end

	-- use this frames dt for fuel and turning, another Wait here would stall it
	local fuelRate = math.abs(throttle) * FUEL_CONSUMPTION_RATE
	if boosting then
		fuelRate += BOOST_FUEL_RATE
	end
	vehicle.Fuel = math.max(0, vehicle.Fuel - fuelRate * dt)
	vehicle.Align.CFrame *= CFrame.Angles(0, -steer * dt * 2.5, 0)

	local forward = vehicle.MonoRoot.CFrame.LookVector
	local targetVelocity = forward * (speedFactor * vehicle.Speed)
	if not vehicle.Climbing then
		-- keep the Y speed on ground so normal gravity still pulls it down
		targetVelocity += Vector3.yAxis * vehicle.LinearVelocity.Y
	end
	vehicle.MonoRoot.AssemblyLinearVelocity = vehicle.LinearVelocity:Lerp(targetVelocity, math.clamp(dt * 5, 0, 1))

	if vehicle.Fuel <= 0 then
		vehicle.Toggle.Movement = false
	end
end

local function createSpeedometer(vehicle: any)
	-- this ui belongs to the controller so it can clean it up when the ride ends
	local gui = Instance.new("BillboardGui")
	gui.Name = "Speedometer"
	gui.Adornee = vehicle.MonoRoot
	gui.Size = UDim2.new(0, 100, 0, 40)
	gui.AlwaysOnTop = true
	gui.Parent = vehicle.Vehicle

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.Font = Enum.Font.Arcade
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Text = [[0 studs]]
	text.Parent = gui

	vehicle.SpeedUI = text
	vehicle.NextUIUpdate = os.clock() + 0.1
end

local function updateSpeedometer(vehicle: any)
	if not vehicle.SpeedUI then return end
	if os.clock() >= vehicle.NextUIUpdate then
		local speed = math.floor(vehicle.LinearVelocity.Magnitude)
		vehicle.SpeedUI.Text = ("%d studs/s"):format(speed)
		vehicle.NextUIUpdate = os.clock() + 0.1
	end
end

local function toggleHeadlights(vehicle: any)
	if vehicle.Headlights then
		vehicle.Headlights.Enabled = not vehicle.Headlights.Enabled
	end
end

local function updateIndicators(vehicle: any)
	if os.clock() >= vehicle.NextIndicatorToggle then
		vehicle.IndicatorGui.Left.Visible = vehicle.Toggle.IndicatorLeft
			and not vehicle.IndicatorGui.Left.Visible
		vehicle.IndicatorGui.Right.Visible = vehicle.Toggle.IndicatorRight
			and not vehicle.IndicatorGui.Right.Visible
		vehicle.NextIndicatorToggle = os.clock() + INDICATOR_INTERVAL
	end
end

local function playHorn(vehicle: any)
	if vehicle.Horn and not vehicle.Horn.IsPlaying then
		vehicle.Horn:Play()
	end
end

local function onRenderStep(dt: number, vehicle: any)
	-- when i get off the seat this should stop the input, camera and force together
	if vehicle.Seat.Occupant ~= vehicle.Humanoid then
		vehicle:Destroy()
		return
	end
	vehicle.LinearVelocity = vehicle.MonoRoot.AssemblyLinearVelocity

	handleSurface(vehicle)
	updateMovement(vehicle, dt)
	updateCamera(vehicle)
	updateSpeedometer(vehicle)
	updateIndicators(vehicle)
end

function MonowheelModule.CreateVehicle(character: Model, monoWheel: Model, enableAll: boolean?)
	-- this has to run client side becuase the camera and keys are for that player
	assert(RunService:IsClient(), "CreateVehicle must run from a client ModuleScript")
	local player = Players.LocalPlayer
	assert(player and player.Character == character, "Use the local player's character")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = monoWheel:FindFirstChild("Root")
	local seat = monoWheel:FindFirstChildOfClass("VehicleSeat")
	local wheel = monoWheel:FindFirstChild("Wheel")
	assert(humanoid, "Character needs a Humanoid")
	assert(root and root:IsA("BasePart") and not root.Anchored, "Monowheel needs an unanchored Root")
	assert(seat and seat.Occupant == humanoid, "Sit in the monowheel VehicleSeat first")
	assert(not activeBySeat[seat], "This VehicleSeat already has a controller")
	assert(wheel and wheel:IsA("BasePart"), "Monowheel needs a Wheel part")
	local attachment = root:FindFirstChild("MainAttachment")
	assert(attachment and attachment:IsA("Attachment"), "Root needs MainAttachment")
	local align = attachment:FindFirstChildOfClass("AlignOrientation")
	local vectorForce = attachment:FindFirstChildOfClass("VectorForce")
	assert(align and vectorForce, "MainAttachment needs AlignOrientation and VectorForce")

	local vehicle = {}
	vehicle.Character = character
	vehicle.Humanoid = humanoid
	vehicle.Vehicle = monoWheel
	vehicle.MonoRoot = root
	vehicle.Seat = seat
	vehicle.Wheel = wheel
	vehicle.Align = align
	vehicle.VectorForce = vectorForce
	vehicle.Params = createBlacklistParams(character, monoWheel)
	vehicle.OriginalWheelProperties = wheel.CustomPhysicalProperties
	vehicle.OriginalAlignCFrame = align.CFrame
	vehicle.OriginalAlignMode = align.Mode
	vehicle.OriginalAlignAttachment = align.Attachment0
	vehicle.OriginalForce = vectorForce.Force
	vehicle.OriginalForceAttachment = vectorForce.Attachment0
	vehicle.OriginalForceRelativeTo = vectorForce.RelativeTo
	vehicle.OriginalForceAtCenter = vectorForce.ApplyAtCenterOfMass
	vehicle.LowFriction = nil
	vehicle.Climbing = false
	vehicle.Destroyed = false
	vehicle.Camera = Workspace.CurrentCamera
	vehicle.OriginalCameraType = vehicle.Camera and vehicle.Camera.CameraType
	vehicle.OriginalCameraSubject = vehicle.Camera and vehicle.Camera.CameraSubject
	if vehicle.Camera and enableAll ~= false then
		vehicle.Camera.CameraType = Enum.CameraType.Scriptable
	end
	-- world space force stays up when the wheel turns, Align uses its attachment
	vectorForce.Attachment0 = attachment
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.ApplyAtCenterOfMass = true
	align.Attachment0 = attachment
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment

	vehicle.Toggle = {
		Camera = enableAll == nil or enableAll,
		Movement = enableAll == nil or enableAll,
		ClimbWalls = enableAll == nil or enableAll,
		Boost = enableAll == nil or enableAll,
		IndicatorLeft = false,
		IndicatorRight = false,
	}

	vehicle.Speed = DEFAULT_SPEED
	vehicle.LinearVelocity = Vector3.new(0, 0, 0)
	vehicle.Fuel = MAX_FUEL
	vehicle.Durability = DURABILITY_MAX
	vehicle.LastImpactAt = -math.huge

	vehicle.Headlights = root:FindFirstChildOfClass("SpotLight")
	vehicle.OwnsHeadlights = vehicle.Headlights == nil
	if not vehicle.Headlights then
		vehicle.Headlights = Instance.new("SpotLight")
		vehicle.Headlights.Parent = root
	end
	vehicle.OriginalHeadlightState = vehicle.Headlights.Enabled
	vehicle.OriginalHeadlightRange = vehicle.Headlights.Range
	vehicle.Headlights.Enabled = false
	vehicle.Headlights.Range = HEADLIGHT_RANGE

	-- horn is optional, if Root has one i use that instead of some random id
	local horn = root:FindFirstChild("Horn")
	vehicle.Horn = if horn and horn:IsA("Sound") then horn else nil

	local indGui = Instance.new("BillboardGui", root)
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

	createSpeedometer(vehicle)

	function vehicle:Destroy()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		if activeBySeat[self.Seat] == self then
			activeBySeat[self.Seat] = nil
		end
		if self.RenderName then
			RunService:UnbindFromRenderStep(self.RenderName)
		end
		if self.TouchConnection then
			self.TouchConnection:Disconnect()
		end
		if self.InputConnection then
			self.InputConnection:Disconnect()
		end
		if Workspace.CurrentCamera == self.Camera and self.Camera then
			self.Camera.CameraType = self.OriginalCameraType
			self.Camera.CameraSubject = self.OriginalCameraSubject
		end

		if self.SpeedUI and self.SpeedUI.Parent then
			self.SpeedUI.Parent:Destroy()
		end
		if self.IndicatorGui and self.IndicatorGui.Left.Parent then
			self.IndicatorGui.Left.Parent:Destroy()
		end

		if self.OwnsHeadlights then
			self.Headlights:Destroy()
		else
			self.Headlights.Enabled = self.OriginalHeadlightState
			self.Headlights.Range = self.OriginalHeadlightRange
		end
		-- put the old constraint settings back so the next ride doesnt inherit mine
		self.Align.CFrame = self.OriginalAlignCFrame
		self.Align.Mode = self.OriginalAlignMode
		self.Align.Attachment0 = self.OriginalAlignAttachment
		self.VectorForce.Force = self.OriginalForce
		self.VectorForce.Attachment0 = self.OriginalForceAttachment
		self.VectorForce.RelativeTo = self.OriginalForceRelativeTo
		self.VectorForce.ApplyAtCenterOfMass = self.OriginalForceAtCenter
		self.Wheel.CustomPhysicalProperties = self.OriginalWheelProperties
	end

	-- only damage on a real hit, the cooldown stops rapid Touched hits counting twice
	vehicle.TouchConnection = root.Touched:Connect(function(hit)
		if vehicle.Destroyed or hit:IsDescendantOf(character) or hit:IsDescendantOf(monoWheel) then
			return
		end
		local now = os.clock()
		local impactSpeed = (root.AssemblyLinearVelocity - hit.AssemblyLinearVelocity).Magnitude
		if impactSpeed < IMPACT_SPEED or now - vehicle.LastImpactAt < IMPACT_COOLDOWN then
			return
		end
		vehicle.LastImpactAt = now
		vehicle.Durability = math.max(0, vehicle.Durability - impactSpeed / 10)
		if vehicle.Durability == 0 then
			vehicle:Destroy()
		end
	end)

	-- only read these keys while im actually riding this seat
	vehicle.InputConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed or vehicle.Destroyed or seat.Occupant ~= humanoid then
			return
		end
		if input.KeyCode == Enum.KeyCode.F then
			toggleHeadlights(vehicle)
		elseif input.KeyCode == Enum.KeyCode.H then
			playHorn(vehicle)
		elseif input.KeyCode == Enum.KeyCode.Q then
			vehicle.Toggle.IndicatorLeft = not vehicle.Toggle.IndicatorLeft
			vehicle.Toggle.IndicatorRight = false
		elseif input.KeyCode == Enum.KeyCode.E then
			vehicle.Toggle.IndicatorRight = not vehicle.Toggle.IndicatorRight
			vehicle.Toggle.IndicatorLeft = false
		end
	end)

	nextVehicleId += 1
	vehicle.RenderName = "MonowheelUpdate_" .. nextVehicleId
	activeBySeat[seat] = vehicle
	RunService:BindToRenderStep(vehicle.RenderName, Enum.RenderPriority.Camera.Value, function(dt)
		onRenderStep(dt, vehicle)
	end)

	return vehicle
end

return MonowheelModule
