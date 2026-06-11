module Centralized_CES_Model

using JuMP, Gurobi, CSV, DataFrames, LinearAlgebra, XLSX
include("D:/Jacky/Python/ADMM_P2P_Python/utils/co_utils.jl")

# ====================================================================
# GLOBAL CACHE: Stores the heavy 69-bus matrices and CSV data in RAM
# ====================================================================
const DATA = Dict{Symbol, Any}()

# ====================================================================
# STEP 1: SETUP FUNCTION (Run this ONCE from MATLAB)
# ====================================================================
function setup_data(bus_sys)
    println("Initializing $(bus_sys)-bus Centralized Model Data...")
    
    # 1. Basic Parameters
    hour = 48
    LoadScaler  = 10
    SolarScaler = 10
    DATA[:bus_sys] = bus_sys
    DATA[:hour] = hour
    
    # Update these paths to match your system
    base_path = "D:/Jacky/Python/ADMM_P2P_Python/data"
    
    # 2. Load Prosumer Load Data
    power_consumption_data = DataFrame(CSV.File("$base_path/Power Consumption_$(bus_sys)_bus.csv"))
    power_consumption = Matrix(power_consumption_data) ./ 2 .* LoadScaler
    power_consumption[:, 26] *= 10
    power_consumption[:, 34] *= 10
    power_consumption[:, 51] *= 10
    num_user = size(power_consumption, 2)
    DATA[:num_user] = num_user
    DATA[:raw_load] = power_consumption
    
    # 3. Load Solar Data
    net_load_data = DataFrame(CSV.File("$base_path/Solar_interpolated_6000.csv"))
    solar_scenarios = Matrix(net_load_data) .* SolarScaler
    solar = solar_scenarios[1, :] # Using scenario 1 for CO
    DATA[:solar] = solar

    # 4. Calculate Net Load & Prosumer Locations
    pros_solar = Int(ceil(num_user / 2))
    net_load = copy(power_consumption')
    net_load[pros_solar:end, :] .-= 1.5 * solar'
    DATA[:P_load] = net_load' # Format: [Hour, Prosumer]
    DATA[:pros_solar] = pros_solar
    
    loc_prosumer = zeros(num_user, bus_sys)
    for i in 1:num_user
        loc_prosumer[i, i+1] = 1 # Shifted by 1 based on your original logic
    end
    DATA[:P_load_bus] = DATA[:P_load] * loc_prosumer
    
    # 5. Pricing and Priorities
    DATA[:buy_bp]           = Matrix(CSV.File("$base_path/buy_price_$(bus_sys).csv", header=false) |> DataFrame)
    DATA[:sell_bp]          = Matrix(CSV.File("$base_path/sell_price_$(bus_sys).csv", header=false) |> DataFrame)
    DATA[:buy_priority]     = Matrix(CSV.File("$base_path/buy_priority_$(bus_sys).csv", header=false) |> DataFrame)
    DATA[:sell_priority]    = Matrix(CSV.File("$base_path/sell_priority_$(bus_sys).csv", header=false) |> DataFrame)
    
    # 6. Grid Data (LinDistFlow Matrices & Limits)
    ptdf = Matrix(CSV.File("$base_path/radial$(bus_sys)bus_PTDF.csv", header=false) |> DataFrame)
    DATA[:num_branch] = size(ptdf, 1)
    
    BranchLimit_data = DataFrame(CSV.File("$base_path/$(bus_sys)_bus_limit_data.csv", header=true))
    DATA[:branch_limit] = BranchLimit_data[!, 1] .* 1000
    
    xf = XLSX.readxlsx("D:/Jacky/Python/ADMM_P2P_Python/data/IEEE$(bus_sys)_LinDistFlow_Matrices_PU.xlsx")
    DATA[:A_matrix] = Float64.(xf["A_Matrix"][2:end, 2:end])
    DATA[:D_r] = Diagonal(Float64.(vec(xf["Vectors_PU"][2:end, 3])))
    DATA[:D_x] = Diagonal(Float64.(vec(xf["Vectors_PU"][2:end, 4])))
    DATA[:a_0] = Float64.(xf["Vectors_PU"][2:end, 2])

    # 7. Prosumer CES Parameters
    BatteryCap = Int(ceil(2 * maximum(solar)))
    DATA[:ub_CES]  = BatteryCap * ones(hour, num_user)
    DATA[:lb_CES]  = zeros(hour, num_user)
    DATA[:ub_CESc] = (BatteryCap / 3) * ones(hour, num_user)
    DATA[:ub_CESd] = (BatteryCap / 3) * ones(hour, num_user)
    DATA[:P_CES0]  = (BatteryCap / 2) * ones(num_user)
    DATA[:efficiency_CES] = 0.9
    DATA[:P2PTrade] = [16, 38]
    DATA[:beta_tnb] = 1.0

    println("Battery Capacity set to: ", BatteryCap, " kWh")
    println("Data successfully loaded and cached in Module!")
end




# ====================================================================
# STEP 2: FITNESS FUNCTION (Called repeatedly by MOMSA)
# ====================================================================
function evaluate_fitness(ces_sizes::Vector{Float64}, ces_locs::Vector{Float64})
    
    # 1. Retrieve Data from Cache
    hour            = DATA[:hour]
    num_user        = DATA[:num_user]
    bus_sys         = DATA[:bus_sys]
    num_branch      = DATA[:num_branch]
    P_load          = DATA[:P_load]
    P_load_bus      = DATA[:P_load_bus]
    efficiency_CES  = DATA[:efficiency_CES]
    P2PTrade        = DATA[:P2PTrade]
    
    # 2. Map MOMSA inputs (Particle) to Grid CES Constraints
    num_ces = length(ces_sizes)
    CES_loc_matrix = zeros(Float64, num_ces, bus_sys)
    for i in 1:num_ces
        bus_idx = Int(round(ces_locs[i])) # Ensure bus location is an integer
        CES_loc_matrix[i, bus_idx] = 1.0
    end
    
    ub_CES_grid = ones(hour) * ces_sizes'
    ub_CEScd_grid = ones(hour) * (ces_sizes' ./ 3) # Max charge/discharge rate
    Pg_CES0 = ces_sizes .* 0.5 # Initial SOC is 50%
    
    # 3. Initialize Gurobi Model
    Central_Model = Model(Gurobi.Optimizer)
    set_optimizer_attribute(Central_Model, "OutputFlag", 0) # Mute solver output for speed
    # set_optimizer_attribute(Central_Model, "Threads", 1)    # Prevent Gurobi from crashing MATLAB
    
    # --- PROSUMER VARIABLES ---
    @variable(Central_Model, nload[1:hour, 1:num_user])
    @variable(Central_Model, P_buy[1:hour, 1:num_user] >= 0)
    @variable(Central_Model, P_sell[1:hour, 1:num_user] >= 0)
    @variable(Central_Model, Pg_buy[1:hour, 1:num_user] >= 0)
    @variable(Central_Model, Pg_sell[1:hour, 1:num_user] >= 0)
    
    @variable(Central_Model, 0 <= P_CES[i=1:hour, j=1:num_user] <= DATA[:ub_CES][i, j])
    @variable(Central_Model, 0 <= P_c[i=1:hour, j=1:num_user] <= DATA[:ub_CESc][i, j])
    @variable(Central_Model, 0 <= P_d[i=1:hour, j=1:num_user] <= DATA[:ub_CESd][i, j])

    # --- GRID VARIABLES ---
    @variable(Central_Model, net_load_kW[1:hour, 1:bus_sys])
    @variable(Central_Model, 0 <= PCES_Grid[i=1:hour, j=1:num_ces] <= ub_CES_grid[i, j])
    @variable(Central_Model, 0 <= Pc_Grid[i=1:hour, j=1:num_ces] <= ub_CEScd_grid[i, j])
    @variable(Central_Model, 0 <= Pd_Grid[i=1:hour, j=1:num_ces] <= ub_CEScd_grid[i, j])

    @variable(Central_Model, P_inj[1:hour, 1:(bus_sys-1)])
    @variable(Central_Model, Q_inj[1:hour, 1:(bus_sys-1)])
    @variable(Central_Model, v[1:hour, 1:(bus_sys-1)])
    p_net = Array{Any}(nothing, hour, bus_sys - 1) 
    q_net = Array{Any}(nothing, hour, bus_sys - 1)

    # --- PROSUMER CONSTRAINTS ---
    B_load = zeros(size(P_load))
    B_load[findall(P_load .> 0)] .= 1
    
    for u in 1:num_user
        # Energy Balance
        @constraint(Central_Model, nload[:, u] .== P_load[:, u] .+ P_c[:, u] .- P_d[:, u])
        @constraint(Central_Model, Pg_buy[:, u] .+ P_buy[:, u] .== nload[:, u] .* B_load[:, u])
        @constraint(Central_Model, Pg_sell[:, u] .+ P_sell[:, u] .== -nload[:, u] .* (1 .- B_load[:, u]))
        
        # Trading Hours
        @constraint(Central_Model, P_buy[1:P2PTrade[1], u] .== 0)
        @constraint(Central_Model, P_buy[P2PTrade[2]:hour, u] .== 0)
        @constraint(Central_Model, P_sell[1:P2PTrade[1], u] .== 0)
        @constraint(Central_Model, P_sell[P2PTrade[2]:hour, u] .== 0)

        # Prosumer CES Dynamics (Extn-LP formulation)
        @constraint(Central_Model, [i in 1:hour-1],    P_c[i+1, u] .<= (DATA[:ub_CES][i, u] .- P_CES[i, u]) ./ efficiency_CES)
        @constraint(Central_Model,                     P_c[1, u] .<= (DATA[:ub_CES][1, u] .- DATA[:P_CES0][u]) ./ efficiency_CES)
        @constraint(Central_Model, [i in 1:hour-1],    P_d[i+1, u] .<= (P_CES[i, u] .- DATA[:lb_CES][i, u]) .* efficiency_CES)
        @constraint(Central_Model,                     P_d[1, u] .<= (DATA[:P_CES0][u] .- DATA[:lb_CES][1, u]) .* efficiency_CES)
        @constraint(Central_Model,                     P_d[:, u] .<= DATA[:ub_CESd][:, u] .- (DATA[:ub_CESd][:, u] ./ DATA[:ub_CESc][:, u]) .* P_c[:, u])
        @constraint(Central_Model,                     P_CES[1, u] == DATA[:P_CES0][u])
        @constraint(Central_Model, [i in 1:hour-1],    P_CES[i+1, u] == P_CES[i, u] + (efficiency_CES * P_c[i, u]) - (P_d[i, u] / efficiency_CES))
        @constraint(Central_Model,                     P_CES[1, u] == P_CES[end, u] + (efficiency_CES * P_c[end, u]) - (P_d[end, u] / efficiency_CES))
    end

    # --- GRID CONSTRAINTS ---
    # 1. Market Clearing (Centralized: what is bought must be sold)
    @constraint(Central_Model, sum(P_buy, dims=2) .== sum(P_sell, dims=2))

    # 2. Grid CES Dynamics
    # Ensure Grid CES takes only prosumers operations
    @constraint(Central_Model, sum((efficiency_CES .* P_c - P_d ./ efficiency_CES), dims=2) .== sum((efficiency_CES .* Pc_Grid - Pd_Grid ./ efficiency_CES), dims=2))
    for c in 1:num_ces
        @constraint(Central_Model, [i in 1:hour-1],    Pc_Grid[i+1, c] .<= (ub_CES_grid[i, c] .- PCES_Grid[i, c]) ./ efficiency_CES)
        @constraint(Central_Model,                     Pc_Grid[1, c] .<= (ub_CES_grid[1, c] .- Pg_CES0[c]) ./ efficiency_CES)
        @constraint(Central_Model, [i in 1:hour-1],    Pd_Grid[i+1, c] .<= (PCES_Grid[i, c] .- DATA[:lb_CES][i, c]) .* efficiency_CES)
        @constraint(Central_Model,                     Pd_Grid[1, c] .<= (Pg_CES0[c] .- DATA[:lb_CES][1, c]) .* efficiency_CES)
        @constraint(Central_Model,                     Pd_Grid[:, c] .<= ub_CEScd_grid[:, c] .- (ub_CEScd_grid[:, c] ./ ub_CEScd_grid[:, c]) .* Pc_Grid[:, c])
        @constraint(Central_Model,                     PCES_Grid[1, c] == Pg_CES0[c])
        @constraint(Central_Model, [i in 1:hour-1],    PCES_Grid[i+1, c] == PCES_Grid[i, c] + (efficiency_CES * Pc_Grid[i, c]) - (Pd_Grid[i, c] / efficiency_CES))
        @constraint(Central_Model,                     PCES_Grid[1, c] == PCES_Grid[end, c] + (efficiency_CES * Pc_Grid[end, c]) - (Pd_Grid[end, c] / efficiency_CES))
    end
    
    # 3. Nodal Balance
    dt = 0.5
    net_load_kW = @expression(Central_Model, (P_load_bus ./ dt) .+ (((Pc_Grid .- Pd_Grid) ./ dt) * CES_loc_matrix))

    # 4. LinDistFlow Constraints (Network Physics)
    A_matrix = DATA[:A_matrix]
    D_r = DATA[:D_r]
    D_x = DATA[:D_x]
    a_0 = DATA[:a_0]
    A_trans = transpose(A_matrix)
    v_0 = 1.0
    S_base = 10000.0
    for t in 1:hour
        # Line Flows
        for i in 1:(bus_sys-1)
            # p_net and q_net containers are size: (hour x 32)
            # We use i+1 to pull from columns 2:33 of the 33-column load matrices
            p_net[t, i] = @expression(Central_Model, -net_load_kW[t, i+1])
            q_net[t, i] = @expression(Central_Model, -(P_load_bus[t, i+1] / dt) * 0.5)
        end
        @constraint(Central_Model, p_net[t, :] .== A_trans * P_inj[t, :])
        
        # q_net[t, :]   is a vector of size (32)
        # A_trans       is a matrix of size (32 x 32)
        # Q_inj[t, :]   is a vector of size (32)
        @constraint(Central_Model, q_net[t, :] .== A_trans * Q_inj[t, :])
        
        # v[t, :]       is a vector of size (32) -> represents voltage at buses 2 to 33
        # A_matrix      is a matrix of size (32 x 32)
        # a_0           is a vector of size (32) -> branch connection to the substation (Bus 1)
        # D_r, D_x      are Diagonal matrices of size (32 x 32) -> Resistance/Reactance
        @constraint(Central_Model, 
            A_matrix * v[t, :] .+ (v_0 .* a_0) .== 
            2 .* D_r * (P_inj[t, :] ./ S_base) .+ 2 .* D_x * (Q_inj[t, :] ./ S_base)
        )

        # Line Limits
        # Voltage Limits (0.95 to 1.05 pu)
        @constraint(Central_Model, -DATA[:branch_limit] .<= P_inj[t, :] .<= DATA[:branch_limit])
        @constraint(Central_Model, -DATA[:branch_limit] .<= Q_inj[t, :] .<= DATA[:branch_limit])
        @constraint(Central_Model, v[t, :] .>= 0.95)
        @constraint(Central_Model, v[t, :] .<= 1.05)
    end

    # --- Disable CES ---
    # @constraint(Central_Model, Pc_Grid .== 0)
    # @constraint(Central_Model, Pd_Grid .== 0)

    # --- OBJECTIVE FUNCTION ---
    f_p2p = sum(P_buy .* DATA[:buy_priority]') + sum(P_sell .* DATA[:sell_priority]')
    f_grid_trade = sum(DATA[:beta_tnb] .* (Pg_buy .+ Pg_sell))
    f_ces_deg = sum(0.005 .* (P_c .+ P_d)) + sum(0.005 .* (Pc_Grid .+ Pd_Grid))
    
    @objective(Central_Model, Min, f_p2p + f_grid_trade + f_ces_deg)

    # --- OPTIMIZE AND RETURN ---
    optimize!(Central_Model)
    
    if termination_status(Central_Model) == MOI.OPTIMAL
        # plotting
        # plot_all(value.(PCES_Grid), value.(Pc_Grid), value.(Pd_Grid), value.(v), value.(P_inj), value.(Q_inj), DATA[:branch_limit])

        # 1. Get the raw values for the Grid CES
        pc_val = value.(Pc_Grid)
        pd_val = value.(Pd_Grid)
        
        # 2. Replicate the C++ 'netload_branchlimit' logic
        # Create a matrix of zeros for all buses: size [Hour, Bus]
        Charge_Discharge_CES = zeros(hour, DATA[:bus_sys])
        
        # Map each CES unit's net charge to its specific Bus Location
        for z in 1:num_ces
            bus_idx = Int(round(ces_locs[z]))
            # Net charge = Charge - Discharge
            Charge_Discharge_CES[:, bus_idx] .= pc_val[:, z] .- pd_val[:, z]
        end
        
        # 3. Calculate your other costs
        pros_cost, TNBearning = ProfitCal(value.(Pg_buy), value.(Pg_sell), value.(P_buy), value.(P_sell))
        # 4. Return the Dictionary
        return Dict(
            "infeasible" => 0,
            "cost" => pros_cost,
            "shape" => size(P_buy),
            "CES_shape" => size(Charge_Discharge_CES),
            "profit" => TNBearning,
            # "P2P_buy" => value.(P_buy),
            # "Grid_buy" => value.(Pg_buy),
            # "P2P_sell" => value.(P_sell),
            # "Grid_sell" => value.(Pg_sell),
            "Charge_Discharge_CES" => Charge_Discharge_CES,
            "load" => DATA[:raw_load],
            "solar" => DATA[:solar],
            "pros_solar" => DATA[:pros_solar],
        )
    else
        return Dict("infeasible" => 1) 
    end
end

end # End of Module