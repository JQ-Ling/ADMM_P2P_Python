# ====================================================================
# SANITY TEST SCRIPT
# Run via terminal: julia --project=. sanity_test.jl
# ====================================================================

# 1. Include and load your module
println("Loading Module...")
# include("../subproblems/CO_Placement.jl") 
include("../subproblems/CO_Placement_ptdf.jl") 
using .Centralized_CES_Model, CSV, DataFrames

function run_test(bus_sys, ces_config)
    # 3. Run the setup_data function (caches data into DATA Dict)
    println("\n=== 1. Testing setup_data() ===")
    @time Centralized_CES_Model.setup_data(bus_sys)

    # 4. Define dummy test parameters for the CES units
    # Ensure they are Float64 vectors as expected by evaluate_fitness
    # Example: 2 CES units -> 50kW at Bus 15, and 100kW at Bus 45.
    to_vector(x) = x isa AbstractVector ? Vector{Float64}(x) : Float64[x]
    
    ces_sizes = to_vector(ces_config["ces_sizes"])
    ces_locs  = to_vector(ces_config["ces_locs"])

    # 5. Run the optimization function
    println("\n=== 2. Testing evaluate_fitness() ===")
    println("Inputs -> Sizes: ", ces_sizes, " | Locations: ", ces_locs)
    
    # We use @time to see exactly how long Gurobi takes to build and solve
    t_fitness = @elapsed results = Centralized_CES_Model.evaluate_fitness(ces_sizes, ces_locs)

    # 6. Display Output gracefully
    println("\n=== 3. Optimization Results ===")
    println("Evaluation Time: ", round(t_fitness, digits=4), " seconds")
    if results["infeasible"] == 0
        println("Status:        SUCCESS (OPTIMAL)")
        results["t_fitness"] = t_fitness  # Store the evaluation time in the results dictionary

        # In CO_Placement.jl, pros_cost might be a vector of 68 users. 
        # We sum it to get the total system cost.
        total_cost = sum(results["cost"])
        
        println("Total Cost:    ", round(total_cost, digits=4))
        println("Total Profit:  ", round(results["profit"], digits=4))
        println("CES Matrix:    ", results["CES_shape"][1], " hours x ", results["CES_shape"][2], " buses")
    else
        println("Status:        FAILED (INFEASIBLE)")
        println("Check if the sizes are too large for the branch limits.")
    end
    return results
end

# Execute the test
bus_sys = 69
moo = ["MOPSO", "MOLA", "MOMSA"]
moo_id = 3

if moo_id == 1
    println("Running MOPSO Test...")
    ces_locs = [8,	27,	59,	35,	11,	63]
    ces_sizes = [211.84476366627757, 300.3269385208485,	277.1108821038113, 163.88045845173997, 209.36410565495092, 216.25005368647368]
elseif moo_id == 2
    println("Running MOLA Test...")
    ces_locs = [57,	61,	27,	60,	26,	29,	35]
    ces_sizes = [269.89305516333525, 188.61089096670472, 276.9143837170337,	219.94337293955118,	277.95853735345986,	126.22330199706694,	210.84117928909714]
elseif moo_id == 3
    println("Running MOMSA Test...")
    ces_locs = [35,	9,	27,	38,	34,	26]
    ces_sizes = [204.38395725238342, 264.17558743868483, 222.59751595840694, 300.5220477088717,	157.79802254036926,	100.66745330445482]
end
ces_config = Dict("ces_sizes" => ces_sizes, "ces_locs" => ces_locs)
results = run_test(bus_sys, ces_config)

# ====================================================================
# CONFIGURATION EXTRACTION
# This section will extract the configuration of the congested scenarios
# including Total Load, Solar, and Power flow related data.
# ====================================================================
# Update these paths to match your system
hour = 48
LoadScaler  = 10
SolarScaler = 10
base_path = "D:/Jacky/Python/ADMM_P2P_Python/data"

# 2. Load Prosumer Load Data
power_consumption_data = DataFrame(CSV.File("$base_path/Power Consumption_$(bus_sys)_bus.csv"))
power_consumption = Matrix(power_consumption_data) ./ 2 .* 10
num_user = size(power_consumption, 2)

if bus_sys == 69
    # Adjust specific prosumer loads for the 69-bus system
    power_consumption[:, 26] *= 10
    power_consumption[:, 34] *= 10
    power_consumption[:, 51] *= 10
else
    # Adjust specific prosumer loads for the 33-bus system
    power_consumption[:,18] *= 20
end

if bus_sys == 33
    net_load_data = DataFrame(CSV.File("$base_path/Solar_interpolated.csv", header=false))
    solar_scenarios = Matrix(net_load_data) .* SolarScaler
    solar = solar_scenarios[1000, :] # Using scenario 1000 for CO
else
    net_load_data = DataFrame(CSV.File("$base_path/Solar_interpolated_6000.csv"))
    solar_scenarios = Matrix(net_load_data) .* SolarScaler
    solar = solar_scenarios[1, :] # Using scenario 1 for CO
end

# 4. Calculate Net Load & Prosumer Locations
pros_solar = Int(ceil(num_user / 2))
net_load = copy(power_consumption')
total_solar = zeros(size(net_load))
if bus_sys == 33
    net_load[23:end, :] .-= solar' * 1.5
    net_load[18, :] .-= solar * 16 * 1.5
    total_solar[23:end, :] .+= solar' * 1.5
    total_solar[18, :] .+= solar * 16 * 1.5
else
    net_load[pros_solar:end, :] .-= 1.5 * solar'
    total_solar[pros_solar:end, :] .+= 1.5 * solar'
end

total_load = sum(power_consumption)
total_solar = sum(total_solar)

println("\n=== 4. Load & Solar Summary ===")
println("Total Load (MW):  ", round(total_load / 1000, digits=2))
println("Total Solar (MW): ", round(total_solar / 1000, digits=2))

branch_limit = results["branch_limit"]
P_inj = results["P_inj"]

if bus_sys == 33
    congested_power = maximum(abs.(P_inj[:,18]))
    branch_congested = branch_limit[18]
    exceed_power = congested_power - branch_congested
else
    congested_power = zeros(3)
    branch_congested = zeros(3)
    exceed_power = zeros(3)

    congested_power[1] = maximum(abs.(P_inj[:,26]))
    congested_power[2] = maximum(abs.(P_inj[:,34]))
    congested_power[3] = maximum(abs.(P_inj[:,51]))
    branch_congested[1] = branch_limit[26]
    branch_congested[2] = branch_limit[34]
    branch_congested[3] = branch_limit[51]

    exceed_power = congested_power .- branch_congested
end

println("\n=== 5. Congestion Summary ===")
if bus_sys == 33
    println("Congested Bus: 18")
else
    println("Congested Buses: 26, 34, 51")
end
println("Congested Power (kW): ", round.(congested_power, digits=2))
println("Branch Limit (kW):    ", round.(branch_congested, digits=2))
println("Exceed Power (kW):    ", round.(exceed_power, digits=2))

# 6. Computational time average
# time_avg = 0

# for i in 1:10
#     results = run_test(bus_sys, ces_config)
#     global time_avg += results["t_fitness"]
# end

# time_avg /= 10
# time_estimate_69 = time_avg * 2.77e34
# time_estimate_69_hr = time_estimate_69/60/60
# MOMSA_time = 32.89
# MOLA_time = 26.59
# MOPSO_time = 27.07

# println("\n=== 6. Computational Time ===")
# println("Average Time (s)               : ", round(time_avg, digits=2))
# println("Estimated Time (hours)         : ", round(time_estimate_69_hr, digits=2))
# println("Acceleration Factor (MOMSA)    : ", round(time_estimate_69_hr/MOMSA_time, digits=2))
# println("Acceleration Factor (MOLA)     : ", round(time_estimate_69_hr/MOLA_time, digits=2))
# println("Acceleration Factor (MOPSO)    : ", round(time_estimate_69_hr/MOPSO_time, digits=2))

# 7. Save trading outcome
P_buy = results["P2P_buy"]
P_sell = results["P2P_sell"]
Pg_buy = results["Grid_buy"]
Pg_sell = results["Grid_sell"]

save_path = "D:/Jacky/Data Output/CES size and loc/Individual Scenario Outcome/$(bus_sys)bus_ptdf/"

# CSV.write("$(save_path)Grid_buy.csv", DataFrame(P_buy, :auto))
# CSV.write("$(save_path)Grid_sell.csv", DataFrame(P_sell, :auto))
# CSV.write("$(save_path)P2P_buy.csv", DataFrame(Pg_buy, :auto))
# CSV.write("$(save_path)P2P_sell.csv", DataFrame(Pg_sell, :auto))
CSV.write("$(save_path)P_inj.csv", DataFrame(P_inj, :auto))