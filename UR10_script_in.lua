sim = require('sim')

jointHandles = {}
jointTorques = {0, 0, 0, 0, 0, 0}
isCrashed = false

-- UR10 Official Maximum Rated Torques (Nm)
maxRatedTorques = {330.0, 330.0, 150.0, 54.0, 54.0, 54.0}

jointTemp = 35.0
jointCurrent = 2.0
isTrip = false
machineState = "Normal"

function sysCall_init()
    coroutine = require('coroutine')
    
    jointHandles = {}
    jointHandles[1] = sim.getObject('/UR10/joint')
    jointHandles[2] = sim.getObject('/UR10/link/joint')
    jointHandles[3] = sim.getObject('/UR10/link/joint/link/joint')
    jointHandles[4] = sim.getObject('/UR10/link/joint/link/joint/link/joint')
    jointHandles[5] = sim.getObject('/UR10/link/joint/link/joint/link/joint/link/joint')
    jointHandles[6] = sim.getObject('/UR10/link/joint/link/joint/link/joint/link/joint/link/joint')
    
    --local allJoints = sim.getObjectsInTree(sim.handle_scene, sim.sceneobject_joint)
    --jointHandles = {}
    
    for i = 1, 6 do
        --jointHandles[i] = allJoints[i]
        if jointHandles[i] ~= -1 then
            sim.setJointMaxForce(jointHandles[i], maxRatedTorques[i])
        end
    end

    maxVel = {0.05, 0.05, 0.05, 0.05, 0.05, 0.05}
    maxAccel = {0.02, 0.02, 0.02, 0.02, 0.02, 0.02}
    maxJerk = {0.01, 0.01, 0.01, 0.01, 0.01, 0.01}

    pos1 = {0, 0, 0, 0, 0, 0}
    pos2 = {
        math.rad(45),
        math.rad(-30),
        math.rad(60),
        math.rad(-45),
        math.rad(90),
        math.rad(-90)
    }
end

function sysCall_thread()
    while true do
        if isCrashed then break end

        sim.moveToConfig({
            joints = jointHandles,
            targetPos = pos2,
            targetPositions = pos2,
            maxVel = maxVel,
            maxAccel = maxAccel,
            maxJerk = maxJerk
        })

        sim.wait(1)

        if isCrashed then break end

        sim.moveToConfig({
            joints = jointHandles,
            targetPos = pos1,
            targetPositions = pos1,
            maxVel = maxVel,
            maxAccel = maxAccel,
            maxJerk = maxJerk
        })

        sim.wait(2)
    end
end

-- This function is called at every simulation step (Ideal for sensors and PLC comms)
function sysCall_sensing()
    if lastPrintTime == nil then lastPrintTime = 0 end
    local simTime = sim.getSimulationTime()

    -- 1. Read real physics torque values (1:1 scale)
    for i = 1, 6 do
        local forceOrTorque = sim.getJointForce(jointHandles[i])
        if forceOrTorque ~= nil then
            jointTorques[i] = math.abs(forceOrTorque)
        end
    end

    -- 2. Predictive Maintenance Timeline & Sensor Spoofing
    if simTime < 120.0 then
        -- Normal Operation Phase (0s - 120s)
        machineState = "Normal"
        -- Current scales with real torque (~2 - 4 A)
        jointCurrent = (jointTorques[3] / 15.0) + 1.0 + ((math.random() - 0.5) * 0.2)
        -- Temperature rises gradually from ambient 35 C to ~42 C
        jointTemp = 35.0 + (simTime * 0.05) + ((math.random() - 0.5) * 0.3)

    elseif simTime >= 120.0 and simTime < 200.0 then
        -- Overload Warning Phase (120s - 150s: 30 seconds hold)
        machineState = "Warning"
        -- Force Joint 3 torque to hold at 185 Nm
        jointTorques[3] = 185.0 + ((math.random() - 0.5) * 4.0)
        -- Force motor current surge (~12 - 13 A)
        jointCurrent = 12.5 + ((math.random() - 0.5) * 0.4)
        -- Rapid thermal accumulation due to excessive mechanical load
        jointTemp = jointTemp + 0.15 + ((math.random() - 0.5) * 0.1)

    elseif simTime >= 200.0 and simTime < 500 then
        -- Catastrophic Failure & Safety Trip Phase (150s - 165s: 15 seconds)
        machineState = "Breakdown"

        if not isTrip then
            isTrip = true
            -- Mechanical brakes lock healthy base and shoulder joints in place
            for _, idx in ipairs({1, 2}) do
                local currentPos = sim.getJointPosition(jointHandles[idx])
                sim.setJointTargetPosition(jointHandles[idx], currentPos)
            end

            -- Release Joint 3 holding force (Elbow structural collapse)
            sim.setJointMaxForce(jointHandles[3], 0)

            -- Power cut to wrist joints (J4, J5, J6 hang loose)
            sim.setJointMaxForce(jointHandles[4], 0)
            sim.setJointMaxForce(jointHandles[5], 0)
            sim.setJointMaxForce(jointHandles[6], 0)
        end

        -- Torque on unpowered joints drops to 0 Nm
        jointTorques[1] = 0.0
        jointTorques[2] = 0.0
        jointTorques[3] = 185
        jointTorques[4] = 0.0
        jointTorques[5] = 0.0
        jointTorques[6] = 0.0

        -- Current cuts to 0 A; temperature slowly dissipates
        jointCurrent = 0.0
        jointTemp = jointTemp - 0.05

    elseif simTime >= 500 then
        -- Simulation stop after holding breakdown state for 15 seconds
        sim.stopSimulation()
    end

    -- 3. Print full diagnostics (Torques, Temp, Current) every 2.0 seconds
    if (simTime - lastPrintTime) > 3.0 then
        print(string.format("[Time: %5.1fs | Status: %-9s] | Temp: %4.1f C | Current: %4.1f A",
            simTime, machineState, jointTemp, jointCurrent))
        print(string.format("Torques (Nm) -> J1: %5.1f | J2: %5.1f | J3: %5.1f | J4: %4.1f | J5: %4.1f | J6: %4.1f",
            jointTorques[1], jointTorques[2], jointTorques[3],
            jointTorques[4], jointTorques[5], jointTorques[6]))
        print()
        lastPrintTime = simTime
    end

    -- 4. Pack complete ML dataset into String Signal for Python middleware
    -- Format: Time, J3_Torque, Temperature, Current, State
    local mlDataPacket = string.format("%.1f,%.2f,%.1f,%.2f,%s", 
        simTime, jointTorques[3], jointTemp, jointCurrent, machineState)
    sim.setStringSignal('UR10_PdM_Data', mlDataPacket)

    -- Pack all 6 torques for PLC monitoring
    local torqueStr = string.format("%.2f,%.2f,%.2f,%.2f,%.2f,%.2f", 
        jointTorques[1], jointTorques[2], jointTorques[3], 
        jointTorques[4], jointTorques[5], jointTorques[6])
    sim.setStringSignal('UR10_Torques', torqueStr)
end


function sysCall_actuation()
    local simTime = sim.getSimulationTime()

    -- Simulate bearing jam on Joint 2: Trigger for 30 seconds (15s to 45s)
    if simTime >= 15.0 and simTime <= 45.0 then
        -- Read current velocity
        local vel = sim.getJointVelocity(jointHandles[2])
        
        -- Apply opposing resistive torque to force the motor to work harder
        local brakingTorque = -vel * 250.0 
        sim.setJointTargetForce(jointHandles[2], math.abs(brakingTorque) + 120.0)
    else
        -- Reset to normal torque limit after demo window ends
        sim.setJointTargetForce(jointHandles[2], 1000.0)
    end
end