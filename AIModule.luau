local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")

local AIModule = {}

local AIStates = setmetatable({}, { __mode = "k" })
local PathQueue = {}

local LOS_MODE = "LineOfSight"
local AVOID_MODE = "Avoidance"
local PATH_MODE = "Path"

local DEFAULT_UPDATE_DT = 0.1
local DEFAULT_LOOKAHEAD_FACTOR = 2.2
local DEFAULT_STOP_RADIUS_SCALE = 0.7
local DEFAULT_REACH_RADIUS_MIN = 1.5
local DEFAULT_REPATH_COOLDOWN = 0.8
local DEFAULT_STUCK_TIME = 1.25
local DEFAULT_PROGRESS_EPSILON = 0.15
local DEFAULT_AVOID_COMMIT_TIME = 0.35
local DEFAULT_MAX_PATH_SOLVES_PER_SECOND = 20
local DEFAULT_PATH_DESTINATION_EPSILON = 3
local DEFAULT_WAYPOINT_REACHED_SCALE = 1.2
local DEFAULT_SEPARATION_RADIUS_SCALE = 2.25
local DEFAULT_SEPARATION_STRENGTH = 0.35

local FAN_ANGLES = { 0, 20, -20, 40, -40, 70, -70, 100, -100 }

local LastQueueTick = os.clock()
local PathSolveBudget = DEFAULT_MAX_PATH_SOLVES_PER_SECOND

local function getRootPart(AI)
	if typeof(AI) ~= "Instance" then
		return nil
	end

	if AI:IsA("BasePart") then
		return AI
	end

	if AI:IsA("Model") then
		return AI.PrimaryPart
	end

	return nil
end

local function getAgentRadius(Part)
	return math.max(Part.Size.X, Part.Size.Z) * 0.5
end

local function getStopRadius(Part, Params)
	if Params and typeof(Params.StopRadius) == "number" then
		return Params.StopRadius
	end

	return math.max(DEFAULT_REACH_RADIUS_MIN, getAgentRadius(Part) * DEFAULT_STOP_RADIUS_SCALE)
end

local function makeVelocityVector(HorizontalDirection, Walkspeed, CurrentVelocityY)
	return vector.create(HorizontalDirection.X * Walkspeed, CurrentVelocityY, HorizontalDirection.Z * Walkspeed)
end

local function stopHorizontalVelocity(Part)
	local CurrentVelocity = Part.AssemblyLinearVelocity
	Part.AssemblyLinearVelocity = vector.create(0, CurrentVelocity.Y, 0)
end

local function getLookAheadDistance(Part, Walkspeed, Params)
	if Params and typeof(Params.LookAheadDistance) == "number" then
		return Params.LookAheadDistance
	end

	local SpeedFactor = math.max(1, Walkspeed)
	return math.max(getAgentRadius(Part) * 2, SpeedFactor * DEFAULT_LOOKAHEAD_FACTOR)
end

local function buildRaycastParams(Part, Params)
	local IgnoreList = { Part }
	if Part.Parent then
		table.insert(IgnoreList, Part.Parent)
	end

	if Params and typeof(Params.IgnoreList) == "table" then
		for _, IgnoreItem in ipairs(Params.IgnoreList) do
			if typeof(IgnoreItem) == "Instance" then
				table.insert(IgnoreList, IgnoreItem)
			end
		end
	end

	local CastParams = RaycastParams.new()
	CastParams.FilterType = Enum.RaycastFilterType.Exclude
	CastParams.FilterDescendantsInstances = IgnoreList
	CastParams.IgnoreWater = Params and Params.IgnoreWater == true or false

	return CastParams
end

local function castDistance(Origin, Direction, MaxDistance, CastParams)
	local HitResult = workspace:Raycast(Origin, Direction.Unit * MaxDistance, CastParams)
	if HitResult then
		return (HitResult.Position - Origin).Magnitude, HitResult
	end

	return MaxDistance, nil
end

local function drawDebugRay(Origin, Direction, IsClear, Params)
	if not (Params and Params.DebugRays) then
		return
	end

	local Length = Direction.Magnitude
	if Length <= 0 then
		return
	end

	local DebugPart = Instance.new("Part")
	DebugPart.Anchored = true
	DebugPart.CanCollide = false
	DebugPart.CanQuery = false
	DebugPart.CanTouch = false
	DebugPart.Material = Enum.Material.Neon
	DebugPart.Color = IsClear and Color3.fromRGB(0, 255, 120) or Color3.fromRGB(255, 70, 70)
	DebugPart.Size = vector.create(0.08, 0.08, Length)
	DebugPart.CFrame = CFrame.lookAt(Origin + (Direction * 0.5), Origin + Direction)
	DebugPart.Parent = workspace
	Debris:AddItem(DebugPart, 0.12)
end

local function getStateForPart(Part)
	local State = AIStates[Part]
	if State then
		return State
	end

	State = {
		Mode = LOS_MODE,
		LastPosition = Part.Position,
		LastProgressTime = os.clock(),
		AvoidCommitUntil = 0,
		AvoidDirection = nil,
		AvoidBias = 1,
		LastDestination = Part.Position,
		LastPathRequest = 0,
		PathWaypoints = nil,
		WaypointIndex = 1,
		QueuedPath = false,
	}
	AIStates[Part] = State
	return State
end

local function getRightVector(FlatDirection)
	local Right = FlatDirection:Cross(Vector3.yAxis)
	if Right.Magnitude < 1e-3 then
		return Vector3.xAxis
	end

	return Right.Unit
end

local function rotateDirectionFlat(Direction, Degrees)
	local Radians = math.rad(Degrees)
	local Cosine = math.cos(Radians)
	local Sine = math.sin(Radians)
	return vector.create(
		Direction.X * Cosine - Direction.Z * Sine,
		0,
		Direction.X * Sine + Direction.Z * Cosine
	)
end

local function sampleAvoidanceDirection(Part, DesiredDirection, Walkspeed, CastParams, Params)
	local Radius = getAgentRadius(Part)
	local LookAheadDistance = getLookAheadDistance(Part, Walkspeed, Params)
	local BestScore = -math.huge
	local BestDirection = nil
	local RightVector = getRightVector(DesiredDirection)
	local HeightOffset = math.max(0.25, Part.Size.Y * 0.1)

	for _, Angle in ipairs(FAN_ANGLES) do
		local CandidateDirection = rotateDirectionFlat(DesiredDirection, Angle)
		if CandidateDirection.Magnitude > 0 then
			CandidateDirection = CandidateDirection.Unit
			local CenterOrigin = Part.Position + vector.create(0, HeightOffset, 0)
			local LeftOrigin = CenterOrigin - (RightVector * Radius)
			local RightOrigin = CenterOrigin + (RightVector * Radius)

			local CenterDistance = castDistance(CenterOrigin, CandidateDirection, LookAheadDistance, CastParams)
			local LeftDistance = castDistance(LeftOrigin, CandidateDirection, LookAheadDistance, CastParams)
			local RightDistance = castDistance(RightOrigin, CandidateDirection, LookAheadDistance, CastParams)
			local ClearanceDistance = math.min(CenterDistance, LeftDistance, RightDistance)

			drawDebugRay(CenterOrigin, CandidateDirection * CenterDistance, CenterDistance >= LookAheadDistance, Params)

			if ClearanceDistance > Radius * 1.05 then
				local AlignmentScore = CandidateDirection:Dot(DesiredDirection)
				local OpenScore = ClearanceDistance / LookAheadDistance
				local SideBias = (Angle > 0 and 1 or (Angle < 0 and -1 or 0))
				local BiasScore = 0
				if SideBias ~= 0 and Params and Params.EnableAvoidBias ~= false then
					BiasScore = SideBias * (Params.AvoidBiasWeight or 0.05)
				end
				local CandidateScore = AlignmentScore * 0.75 + OpenScore * 0.25 + BiasScore
				if CandidateScore > BestScore then
					BestScore = CandidateScore
					BestDirection = CandidateDirection
				end
			end
		end
	end

	return BestDirection
end

local function refreshPathSolveBudget(MaxPathSolvesPerSecond)
	local Now = os.clock()
	local Delta = Now - LastQueueTick
	LastQueueTick = Now
	PathSolveBudget = math.min(MaxPathSolvesPerSecond, PathSolveBudget + Delta * MaxPathSolvesPerSecond)
end

local function processPathQueue(MaxPathSolvesPerSecond)
	refreshPathSolveBudget(MaxPathSolvesPerSecond)

	while PathSolveBudget >= 1 and #PathQueue > 0 do
		PathSolveBudget -= 1
		local Entry = table.remove(PathQueue, 1)
		local Part = Entry.Part
		local State = AIStates[Part]
		if State and Part.Parent then
			local Path = PathfindingService:CreatePath(Entry.AgentSettings)
			local Success = pcall(function()
				Path:ComputeAsync(Part.Position, Entry.Destination)
			end)
			if Success and Path.Status == Enum.PathStatus.Success then
				State.PathWaypoints = Path:GetWaypoints()
				State.WaypointIndex = 2
				State.Mode = PATH_MODE
			else
				State.PathWaypoints = nil
				State.WaypointIndex = 1
			end
			State.QueuedPath = false
			State.LastPathRequest = os.clock()
		end
	end
end

local function queuePathRequest(Part, State, Destination, Params)
	if State.QueuedPath then
		return
	end

	local Radius = getAgentRadius(Part)
	local AgentSettings = {
		AgentRadius = math.max(1, Radius),
		AgentHeight = math.max(2, Part.Size.Y),
		AgentCanJump = Params and Params.AllowJump == true or false,
		AgentCanClimb = Params and Params.AllowClimb == true or false,
	}

	State.QueuedPath = true
	table.insert(PathQueue, {
		Part = Part,
		Destination = Destination,
		AgentSettings = AgentSettings,
	})
end

local function applySeparation(Part, DesiredDirection, Params)
	if not (Params and Params.EnableSeparation) then
		return DesiredDirection
	end

	local Radius = getAgentRadius(Part)
	local SeparationRadius = Params.SeparationRadius or (Radius * DEFAULT_SEPARATION_RADIUS_SCALE)
	local OverlapParams = OverlapParams.new()
	OverlapParams.FilterType = Enum.RaycastFilterType.Exclude
	OverlapParams.FilterDescendantsInstances = { Part, Part.Parent }

	if typeof(Params.IgnoreList) == "table" then
		for _, IgnoreItem in ipairs(Params.IgnoreList) do
			if typeof(IgnoreItem) == "Instance" then
				table.insert(OverlapParams.FilterDescendantsInstances, IgnoreItem)
			end
		end
	end

	local NearbyParts = workspace:GetPartBoundsInRadius(Part.Position, SeparationRadius, OverlapParams)
	if #NearbyParts == 0 then
		return DesiredDirection
	end

	local Repulsion = vector.create(0, 0, 0)
	for _, NearbyPart in ipairs(NearbyParts) do
		if NearbyPart:IsA("BasePart") then
			local Offset = Part.Position - NearbyPart.Position
			local Distance = Offset.Magnitude
			if Distance > 0 and Distance < SeparationRadius then
				Repulsion += Offset.Unit * ((SeparationRadius - Distance) / SeparationRadius)
			end
		end
	end

	if Repulsion.Magnitude < 1e-3 then
		return DesiredDirection
	end

	local SeparationStrength = Params.SeparationStrength or DEFAULT_SEPARATION_STRENGTH
	local Blended = DesiredDirection + (Repulsion.Unit * SeparationStrength)
	if Blended.Magnitude <= 0 then
		return DesiredDirection
	end

	return Blended.Unit
end

function AIModule.moveAI(AI, Destination, Walkspeed, Params)
	local Part = getRootPart(AI)
	if not Part or typeof(Destination) ~= "Vector3" or typeof(Walkspeed) ~= "number" then
		return false
	end

	local State = getStateForPart(Part)
	local Now = os.clock()
	local UpdateDt = Params and Params.UpdateDeltaTime or DEFAULT_UPDATE_DT
	local MaxPathSolves = Params and Params.MaxPathSolvesPerSecond or DEFAULT_MAX_PATH_SOLVES_PER_SECOND
	processPathQueue(MaxPathSolves)

	if Params and Params.EnforceServerNetworkOwnership then
		Part:SetNetworkOwner(nil)
	end

	local ToDestination = Destination - Part.Position
	local HorizontalToDestination = vector.create(ToDestination.X, 0, ToDestination.Z)
	local HorizontalDistance = HorizontalToDestination.Magnitude
	local StopRadius = getStopRadius(Part, Params)

	if HorizontalDistance <= StopRadius then
		stopHorizontalVelocity(Part)
		State.Mode = LOS_MODE
		State.PathWaypoints = nil
		State.WaypointIndex = 1
		State.AvoidDirection = nil
		State.LastDestination = Destination
		State.LastPosition = Part.Position
		State.LastProgressTime = Now
		return true
	end

	local MovementSinceLast = (Part.Position - State.LastPosition).Magnitude
	local ProgressEpsilon = Params and Params.ProgressEpsilon or DEFAULT_PROGRESS_EPSILON
	if MovementSinceLast > ProgressEpsilon then
		State.LastProgressTime = Now
		State.LastPosition = Part.Position
	end

	local StuckTime = Params and Params.StuckTime or DEFAULT_STUCK_TIME
	local IsStuck = (Now - State.LastProgressTime) > StuckTime
	local DestinationChangedDistance = (Destination - State.LastDestination).Magnitude
	local DestinationChanged = DestinationChangedDistance >= (Params and Params.PathDestinationEpsilon or DEFAULT_PATH_DESTINATION_EPSILON)
	if DestinationChanged then
		State.PathWaypoints = nil
		State.WaypointIndex = 1
		State.Mode = LOS_MODE
	end
	State.LastDestination = Destination

	local CastParams = buildRaycastParams(Part, Params)
	local DesiredDirection = HorizontalToDestination.Unit
	DesiredDirection = applySeparation(Part, DesiredDirection, Params)
	local LookAheadDistance = getLookAheadDistance(Part, Walkspeed, Params)
	local CenterOrigin = Part.Position + vector.create(0, math.max(0.25, Part.Size.Y * 0.1), 0)
	local DirectHit = workspace:Raycast(CenterOrigin, DesiredDirection * math.min(HorizontalDistance, LookAheadDistance), CastParams)
	drawDebugRay(CenterOrigin, DesiredDirection * math.min(HorizontalDistance, LookAheadDistance), not DirectHit, Params)

	if not DirectHit then
		Part.AssemblyLinearVelocity = makeVelocityVector(DesiredDirection, Walkspeed, Part.AssemblyLinearVelocity.Y)
		State.Mode = LOS_MODE
		State.AvoidDirection = nil
		State.PathWaypoints = nil
		State.WaypointIndex = 1
		return true
	end

	if State.AvoidDirection and Now < State.AvoidCommitUntil then
		Part.AssemblyLinearVelocity = makeVelocityVector(State.AvoidDirection, Walkspeed, Part.AssemblyLinearVelocity.Y)
		State.Mode = AVOID_MODE
		return true
	end

	local AvoidDirection = sampleAvoidanceDirection(Part, DesiredDirection, Walkspeed, CastParams, Params)
	if AvoidDirection then
		local CommitTime = Params and Params.AvoidCommitTime or DEFAULT_AVOID_COMMIT_TIME
		State.AvoidDirection = AvoidDirection
		State.AvoidCommitUntil = Now + CommitTime
		Part.AssemblyLinearVelocity = makeVelocityVector(AvoidDirection, Walkspeed, Part.AssemblyLinearVelocity.Y)
		State.Mode = AVOID_MODE
		return true
	end

	State.Mode = PATH_MODE
	State.AvoidDirection = nil
	if IsStuck then
		State.AvoidBias *= -1
	end

	local RepathCooldown = Params and Params.RepathCooldown or DEFAULT_REPATH_COOLDOWN
	if DestinationChanged or IsStuck or (Now - State.LastPathRequest) >= RepathCooldown or not State.PathWaypoints then
		queuePathRequest(Part, State, Destination, Params)
	end

	if State.PathWaypoints and State.WaypointIndex <= #State.PathWaypoints then
		local Waypoint = State.PathWaypoints[State.WaypointIndex]
		local WaypointOffset = Waypoint.Position - Part.Position
		local WaypointHorizontal = vector.create(WaypointOffset.X, 0, WaypointOffset.Z)
		local WaypointDistance = WaypointHorizontal.Magnitude
		local WaypointReachedRadius = math.max(getAgentRadius(Part) * DEFAULT_WAYPOINT_REACHED_SCALE, StopRadius)
		if WaypointDistance <= WaypointReachedRadius then
			State.WaypointIndex += 1
			if State.WaypointIndex > #State.PathWaypoints then
				stopHorizontalVelocity(Part)
				return true
			end
			Waypoint = State.PathWaypoints[State.WaypointIndex]
			WaypointOffset = Waypoint.Position - Part.Position
			WaypointHorizontal = vector.create(WaypointOffset.X, 0, WaypointOffset.Z)
		end

		if WaypointHorizontal.Magnitude > 0 then
			local PathDirection = WaypointHorizontal.Unit
			Part.AssemblyLinearVelocity = makeVelocityVector(PathDirection, Walkspeed, Part.AssemblyLinearVelocity.Y)
			return true
		end
	end

	local DampenedSpeed = math.max(0, Walkspeed * (1 - math.clamp(UpdateDt, 0, 1)))
	Part.AssemblyLinearVelocity = makeVelocityVector(DesiredDirection, DampenedSpeed, Part.AssemblyLinearVelocity.Y)
	return true
end

return AIModule
