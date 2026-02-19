local PathfindingService = game:GetService("PathfindingService")

local AIModule = {}

local UP = Vector3.new(0, 1, 0)
local EPSILON = 1e-4
local SIDE_FLIP_LIMIT = 4

local DEFAULT_LOOK_AHEAD_SECONDS = 0.4
local DEFAULT_AVOID_COMMIT_SECONDS = 0.75
local DEFAULT_PROGRESS_TIMEOUT_SECONDS = 2.0
local DEFAULT_REPATH_COOLDOWN_SECONDS = 1.25

local StateByAI = setmetatable({}, { __mode = "k" })

local function GetRootPart(AI)
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

local function GetBoundsSize(AI, RootPart)
	if AI and AI:IsA("Model") then
		return AI:GetExtentsSize()
	end
	return RootPart.Size
end

local function GetHorizontalRadius(BoundsSize)
	return math.max(BoundsSize.X, BoundsSize.Z) * 0.5
end

local function NormalizeHorizontal(Vector)
	local Flattened = Vector3.new(Vector.X, 0, Vector.Z)
	local Magnitude = Flattened.Magnitude
	if Magnitude <= EPSILON then
		return Vector3.zero
	end
	return Flattened / Magnitude
end

local function BuildRaycastParams(IgnoreList)
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.FilterDescendantsInstances = IgnoreList
	Params.IgnoreWater = true
	return Params
end

local function CastRay(StartPosition, Direction, RayParams)
	if Direction.Magnitude <= EPSILON then
		return nil
	end
	return workspace:Raycast(StartPosition, Direction, RayParams)
end

local function HasLineOfSight(Origin, Target, RayParams)
	return CastRay(Origin, Target - Origin, RayParams) == nil
end

local function ClearDirectionWithRadius(Origin, MoveDirection, LookAheadDistance, Radius, RayParams)
	local FlatDirection = NormalizeHorizontal(MoveDirection)
	if FlatDirection == Vector3.zero then
		return false
	end

	local Right = FlatDirection:Cross(UP)
	if Right.Magnitude <= EPSILON then
		Right = Vector3.new(1, 0, 0)
	else
		Right = Right.Unit
	end

	local RayDirection = FlatDirection * LookAheadDistance
	local SideOffset = Right * Radius

	local CenterHit = CastRay(Origin, RayDirection, RayParams)
	if CenterHit then
		return false
	end

	local LeftHit = CastRay(Origin - SideOffset, RayDirection, RayParams)
	if LeftHit then
		return false
	end

	local RightHit = CastRay(Origin + SideOffset, RayDirection, RayParams)
	if RightHit then
		return false
	end

	return true
end

local function AssignHorizontalVelocity(RootPart, HorizontalDirection, Walkspeed)
	local HorizontalUnit = NormalizeHorizontal(HorizontalDirection)
	local HorizontalVelocity = HorizontalUnit * Walkspeed
	local CurrentY = RootPart.AssemblyLinearVelocity.Y
	RootPart.AssemblyLinearVelocity = vector.create(HorizontalVelocity.X, CurrentY, HorizontalVelocity.Z)
end

local function StopHorizontalVelocity(RootPart)
	local CurrentY = RootPart.AssemblyLinearVelocity.Y
	RootPart.AssemblyLinearVelocity = vector.create(0, CurrentY, 0)
end

local function GetOrCreateState(RootPart)
	local State = StateByAI[RootPart]
	if State then
		return State
	end

	State = {
		Mode = "Direct",
		SideSign = 1,
		AvoidUntil = 0,
		StartDistanceToGoal = math.huge,
		LastDistance = math.huge,
		LastProgressTime = 0,
		StuckFlips = 0,
		NextRepathTime = 0,
		FallbackPath = nil,
		FallbackWaypointIndex = 1,
		NetworkOwnerForced = false,
	}
	StateByAI[RootPart] = State
	return State
end

local function ConfigureNetworkOwner(State, RootPart, ForceServerNetworkOwner)
	if not ForceServerNetworkOwner or State.NetworkOwnerForced then
		return
	end
	State.NetworkOwnerForced = true
	pcall(function()
		RootPart:SetNetworkOwner(nil)
	end)
end

local function BuildAgentParams(BoundsSize, Params)
	local Radius = GetHorizontalRadius(BoundsSize)
	local Height = BoundsSize.Y
	local CanJump = Params.AgentCanJump == true
	local WaypointSpacing = math.max(2, Radius * 1.5)

	return {
		AgentRadius = math.max(1, math.floor(Radius + 0.5)),
		AgentHeight = math.max(2, math.floor(Height + 0.5)),
		AgentCanJump = CanJump,
		WaypointSpacing = WaypointSpacing,
	}
end

local function ComputeFallbackPath(State, RootPart, Destination, BoundsSize, Params, Now)
	if Now < State.NextRepathTime then
		return false
	end

	State.NextRepathTime = Now + (Params.RepathCooldownSeconds or DEFAULT_REPATH_COOLDOWN_SECONDS)

	local Path = PathfindingService:CreatePath(BuildAgentParams(BoundsSize, Params))
	Path:ComputeAsync(RootPart.Position, Destination)
	if Path.Status ~= Enum.PathStatus.Success then
		State.FallbackPath = nil
		State.FallbackWaypointIndex = 1
		return false
	end

	State.FallbackPath = Path:GetWaypoints()
	State.FallbackWaypointIndex = 1
	return #State.FallbackPath > 0
end

local function FollowFallbackPath(State, RootPart, Destination, Walkspeed, StopRadius, RayParams)
	if not State.FallbackPath or #State.FallbackPath == 0 then
		return false
	end

	if HasLineOfSight(RootPart.Position, Destination, RayParams) then
		State.FallbackPath = nil
		State.FallbackWaypointIndex = 1
		return false
	end

	while State.FallbackWaypointIndex <= #State.FallbackPath do
		local Waypoint = State.FallbackPath[State.FallbackWaypointIndex]
		if (Waypoint.Position - RootPart.Position).Magnitude <= StopRadius then
			State.FallbackWaypointIndex += 1
		else
			break
		end
	end

	if State.FallbackWaypointIndex > #State.FallbackPath then
		State.FallbackPath = nil
		State.FallbackWaypointIndex = 1
		return false
	end

	local CurrentWaypoint = State.FallbackPath[State.FallbackWaypointIndex]
	AssignHorizontalVelocity(RootPart, CurrentWaypoint.Position - RootPart.Position, Walkspeed)
	return true
end

function AIModule.moveAI(Destination, Walkspeed, AI, Params)
	Params = Params or {}

	local RootPart = GetRootPart(AI)
	if not RootPart then
		return
	end
	if typeof(Destination) ~= "Vector3" or typeof(Walkspeed) ~= "number" or Walkspeed <= 0 then
		StopHorizontalVelocity(RootPart)
		return
	end

	local BoundsSize = GetBoundsSize(AI, RootPart)
	local Radius = GetHorizontalRadius(BoundsSize)
	local StopRadius = Params.StopRadius or math.max(1, Radius * 0.75)
	local LookAheadSeconds = Params.LookAheadSeconds or DEFAULT_LOOK_AHEAD_SECONDS
	local AvoidCommitSeconds = Params.AvoidCommitSeconds or DEFAULT_AVOID_COMMIT_SECONDS
	local ProgressTimeoutSeconds = Params.ProgressTimeoutSeconds or DEFAULT_PROGRESS_TIMEOUT_SECONDS
	local UseFallbackPathfinding = Params.UseFallbackPathfinding ~= false

	local DistanceToGoal = (Destination - RootPart.Position).Magnitude
	if DistanceToGoal <= StopRadius then
		StopHorizontalVelocity(RootPart)
		return
	end

	local State = GetOrCreateState(RootPart)
	local Now = os.clock()

	ConfigureNetworkOwner(State, RootPart, Params.ForceServerNetworkOwner == true)

	local IgnoreList = table.create(2 + (Params.IgnoreInstances and #Params.IgnoreInstances or 0))
	IgnoreList[1] = AI
	if Params.IgnoreInstances then
		for Index = 1, #Params.IgnoreInstances do
			IgnoreList[#IgnoreList + 1] = Params.IgnoreInstances[Index]
		end
	end
	local RayParams = BuildRaycastParams(IgnoreList)

	if FollowFallbackPath(State, RootPart, Destination, Walkspeed, StopRadius, RayParams) then
		return
	end

	local GoalDirection = Destination - RootPart.Position
	local BlockingHit = CastRay(RootPart.Position, GoalDirection, RayParams)
	local LineOfSight = BlockingHit == nil

	local ProgressMargin = math.max(0.5, Radius * 0.3)
	local ScaledProgressTimeout = ProgressTimeoutSeconds * math.max(0.75, Radius / math.max(1, Walkspeed))

	if LineOfSight then
		if State.Mode == "EdgeWalk" then
			if DistanceToGoal <= State.StartDistanceToGoal - ProgressMargin then
				State.Mode = "Direct"
				State.StuckFlips = 0
			else
				local SideVector = NormalizeHorizontal(GoalDirection)
				AssignHorizontalVelocity(RootPart, SideVector, Walkspeed)
				return
			end
		end

		State.LastDistance = DistanceToGoal
		State.LastProgressTime = Now
		AssignHorizontalVelocity(RootPart, GoalDirection, Walkspeed)
		return
	end

	if State.Mode ~= "EdgeWalk" then
		State.Mode = "EdgeWalk"
		State.AvoidUntil = Now + AvoidCommitSeconds
		State.StartDistanceToGoal = DistanceToGoal
		State.LastDistance = DistanceToGoal
		State.LastProgressTime = Now
		State.StuckFlips = 0
	end

	if DistanceToGoal < State.LastDistance - ProgressMargin then
		State.LastDistance = DistanceToGoal
		State.LastProgressTime = Now
	end

	if Now > State.AvoidUntil and (Now - State.LastProgressTime) > ScaledProgressTimeout then
		State.SideSign *= -1
		State.StuckFlips += 1
		State.AvoidUntil = Now + AvoidCommitSeconds
		State.StartDistanceToGoal = DistanceToGoal
		State.LastDistance = DistanceToGoal
		State.LastProgressTime = Now
	end

	local HitNormal = BlockingHit and BlockingHit.Normal or Vector3.new(0, 0, 1)
	local BaseTangent = HitNormal:Cross(UP)
	if BaseTangent.Magnitude <= EPSILON then
		local FallbackRight = NormalizeHorizontal(GoalDirection):Cross(UP)
		BaseTangent = FallbackRight.Magnitude > EPSILON and FallbackRight or Vector3.new(1, 0, 0)
	end
	BaseTangent = BaseTangent.Unit

	local TangentA = BaseTangent
	local TangentB = -BaseTangent
	local ChosenTangent = State.SideSign >= 0 and TangentA or TangentB
	local AlternateTangent = State.SideSign >= 0 and TangentB or TangentA

	local LookAheadDistance = math.max(Radius * 1.5, Walkspeed * LookAheadSeconds)
	local ChosenClear = ClearDirectionWithRadius(RootPart.Position, ChosenTangent, LookAheadDistance, Radius, RayParams)
	local AlternateClear = ClearDirectionWithRadius(RootPart.Position, AlternateTangent, LookAheadDistance, Radius, RayParams)

	if not ChosenClear and AlternateClear and Now >= State.AvoidUntil then
		State.SideSign *= -1
		State.AvoidUntil = Now + AvoidCommitSeconds
		ChosenTangent = AlternateTangent
		ChosenClear = true
	end

	if ChosenClear then
		AssignHorizontalVelocity(RootPart, ChosenTangent, Walkspeed)
		return
	end

	if UseFallbackPathfinding and State.StuckFlips >= SIDE_FLIP_LIMIT then
		if ComputeFallbackPath(State, RootPart, Destination, BoundsSize, Params, Now) then
			if FollowFallbackPath(State, RootPart, Destination, Walkspeed, StopRadius, RayParams) then
				return
			end
		end
	end

	AssignHorizontalVelocity(RootPart, AlternateTangent, Walkspeed * 0.6)
end

return AIModule
