function sysCall_init()
    sim = require('sim')

    -- Retrieve base joint handle via absolute path
    jointHandle = sim.getObject('/UR10/joint')

    -- Set oscillation limits (-60 deg to +60 deg)
    targets = {-math.rad(60), math.rad(60)}
    targetIndex = 1
    currentPos = 0

    -- Joint incremental motion speed
    stepSpeed = 0.005

    -- Set base torque and joint dynamic limits
    baseTorque = 45.0
    sim.setJointTargetForce(jointHandle, 100.0)
end

function sysCall_actuation()
    local targetPos = targets[targetIndex]

    -- Step-by-step position tracking
    if math.abs(targetPos - currentPos) > stepSpeed then
        if targetPos > currentPos then
            currentPos = currentPos + stepSpeed
        else
            currentPos = currentPos - stepSpeed
        end
    else
        -- Reverse direction when reaching targets
        targetIndex = targetIndex == 1 and 2 or 1
    end

    sim.setJointTargetPosition(jointHandle, currentPos)
end

function sysCall_sensing()
    -- 1. Read actual joint angle in degrees
    local actualRad = sim.getJointPosition(jointHandle)
    local angleDeg = math.deg(actualRad)

    -- 2. Simulate dynamic load torque based on arm position
    local torqueNm = baseTorque + (math.abs(math.sin(actualRad)) * 20.0) + (math.random() * 2.0)

    -- 3. Calculate simulated vibration (mm/s)
    local vibration = 1.2 + (math.abs(stepSpeed) * 100) + (math.random() * 0.4)

    -- 4. Calculate simulated temperature (?C)
    local temperature = 38.0 + (torqueNm * 0.12)

    -- Export values as float signals for external Python middleware
    sim.setFloatSignal("robot_joint_angle", angleDeg)
    sim.setFloatSignal("robot_joint_torque", torqueNm)
    sim.setFloatSignal("robot_vibration", vibration)
    sim.setFloatSignal("robot_temperature", temperature)
end

function sysCall_cleanup()
    -- Clear signals upon simulation stop
    sim.clearFloatSignal("robot_joint_angle")
    sim.clearFloatSignal("robot_joint_torque")
    sim.clearFloatSignal("robot_vibration")
    sim.clearFloatSignal("robot_temperature")
end