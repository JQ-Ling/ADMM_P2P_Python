module Centralized_CES_Model

using JuMP, Gurobi, CSV, DataFrames, LinearAlgebra, XLSX
include("D:/Jacky/Python/ADMM_P2P_Python/utils/co_utils.jl")

# ====================================================================
# GLOBAL CACHE: Stores the heavy 69-bus matrices and CSV data in RAM
# ====================================================================
const DATA = Dict{Symbol, Any}()

# Per-unit power base (kVA). Used by the LinDistFlow constraint in solve_day and
# returned so the caller can convert branch flows back to per-unit for the loss.
const S_BASE = 10000.0

# ====================================================================
# STEP 1: SETUP FUNCTION (Run this ONCE from MATLAB)
# ====================================================================
function setup_data(bus_sys)
    println("\n*****************************************************")
    println("Initializing $(bus_sys)-bus Centralized Model Data...")
    println("Loading Data for a Week...")
    @assert bus_sys == 33 "Only 33-bus systems are supported."

    # 1. Basic Parameters
    hour = 48                   # Optimisation horizon of ONE day (half-hourly)
    LoadScaler  = 0.45
    SolarScaler = 1.15
    DATA[:bus_sys] = bus_sys
    DATA[:hour] = hour

    # Update these paths to match your system
    base_path = "D:/Jacky/Python/ADMM_P2P_Python/data"
    week_path = "$base_path/ROI_7days"

    # 2. Load Prosumer Load Data
    power_consumption_data = DataFrame(CSV.File("$week_path/Power Consumption_$(bus_sys)_bus_7days.csv"))
    power_consumption = Matrix(power_consumption_data[:,2:end]) .* LoadScaler
    tot_hour, num_user = size(power_consumption)
    DATA[:raw_load_full] = copy(power_consumption)
    # if bus_sys == 69
    #     # Adjust specific prosumer loads for the 69-bus system
    #     power_consumption[:, 26] *= 10
    #     power_consumption[:, 34] *= 10
    #     power_consumption[:, 51] *= 10
    # else
    #     # Adjust specific prosumer loads for the 33-bus system
    #     power_consumption[:,18] *= 20
    # end

    # 3. Load Solar Data
    # NOTE: only the 33-bus week file exists so far. The 69-bus branch is kept
    # for when "Solar_69_bus_7days.csv" / the matching load file are prepared.
    solar_file = bus_sys == 33 ? "Solar_7days.csv" : "Solar_$(bus_sys)_bus_7days.csv"
    net_load_data = DataFrame(CSV.File("$week_path/$solar_file")) # multiply with nominal load, hence contain the PV for each bus
    solar = Matrix(net_load_data[:,2:end]) .* SolarScaler
    @assert size(solar) == size(power_consumption) "Load $(size(power_consumption)) and Solar $(size(solar)) must share the same [Hour, Prosumer] shape."

    # 3b. Split the horizon into whole days
    @assert tot_hour % hour == 0 "Data length ($tot_hour) is not a whole multiple of the daily horizon ($hour)."
    num_days = tot_hour ÷ hour
    DATA[:tot_hour] = tot_hour
    DATA[:num_days] = num_days

    # 4. Calculate Net Load & Prosumer Locations
    if bus_sys == 69
        pros_solar = Int(ceil(num_user / 2))                        # 69-bus: fill in once its week data exists
    else
        pros_solar = [18, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]   # Prosumer indices with solar panels
    end
    net_load = power_consumption .- solar   # Format: [Hour, Prosumer]

    DATA[:P_load_full] = net_load
    DATA[:pros_solar] = pros_solar
    DATA[:solar_full] = solar
    DATA[:num_user] = num_user

    loc_prosumer = zeros(num_user, bus_sys)
    for i in 1:num_user
        loc_prosumer[i, i+1] = 1 # Shifted by 1 based on your original logic
    end
    DATA[:P_load_bus_full] = DATA[:P_load_full] * loc_prosumer

    # 5. Pricing and Priorities (one representative day, reused for every day)
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

    # 7. Prosumer CES Parameters (sized for ONE day, i.e. [hour, num_user])
    BatteryCap = Int(ceil(2 * maximum(solar)))
    DATA[:ub_CES]  = BatteryCap * ones(hour, num_user)
    DATA[:lb_CES]  = zeros(hour, num_user)
    DATA[:ub_CESc] = (BatteryCap / 3) * ones(hour, num_user)
    DATA[:ub_CESd] = (BatteryCap / 3) * ones(hour, num_user)
    DATA[:P_CES0]  = (BatteryCap / 2) * ones(num_user)
    DATA[:efficiency_CES] = 0.9
    DATA[:P2PTrade] = [16, 38]
    DATA[:beta_tnb] = 1.0

    set_day!(1)     # Start pointed at day 1

    println("Battery Capacity set to: ", BatteryCap, " kWh")
    println("Horizon: $num_days day(s) x $hour steps = $tot_hour steps")
    println("Data successfully loaded and cached in Module!")
    println("*****************************************************\n")
end

# Rows of the week-long matrices that belong to day `d`
day_range(d::Int) = ((d - 1) * DATA[:hour] + 1):(d * DATA[:hour])

# Point the day-scoped cache keys at day `d`.
# Everything downstream (solve_day, ProfitCal in co_utils.jl) reads :P_load,
# :P_load_bus, :raw_load and :solar expecting a single 48-step day, so the week
# is kept in the :*_full keys and only one day is exposed at a time.
function set_day!(d::Int)
    rows = day_range(d)
    DATA[:day]        = d
    DATA[:P_load]     = DATA[:P_load_full][rows, :]
    DATA[:P_load_bus] = DATA[:P_load_bus_full][rows, :]
    DATA[:raw_load]   = DATA[:raw_load_full][rows, :]
    DATA[:solar]      = DATA[:solar_full][rows, :]
    return rows
end


# ====================================================================
# STEP 2a: SINGLE-DAY SOLVE (internal helper, one 48-step LP)
#          Operates on whichever day set_day! currently points at.
# ====================================================================
function solve_day(CES_loc_matrix::Matrix{Float64},
                   ub_CES_grid::Matrix{Float64},
                   ub_CEScd_grid::Matrix{Float64},
                   Pg_CES0::Vector{Float64})

    # 1. Retrieve Data from Cache (already sliced down to the current day)
    hour            = DATA[:hour]
    num_user        = DATA[:num_user]
    bus_sys         = DATA[:bus_sys]
    P_load          = DATA[:P_load]
    P_load_bus      = DATA[:P_load_bus]
    efficiency_CES  = DATA[:efficiency_CES]
    P2PTrade        = DATA[:P2PTrade]

    num_ces = size(CES_loc_matrix, 1)

    # 2. Initialize Gurobi Model
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
        @constraint(Central_Model, [i in 1:hour-1],    Pd_Grid[i+1, c] .<= (PCES_Grid[i, c] .- 0.0) .* efficiency_CES)
        @constraint(Central_Model,                     Pd_Grid[1, c] .<= (Pg_CES0[c] .- 0.0) .* efficiency_CES)
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
    S_base = S_BASE
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

    if termination_status(Central_Model) != MOI.OPTIMAL
        return nothing
    end

    # plotting
    # plot_all(value.(PCES_Grid), value.(Pc_Grid), value.(Pd_Grid), value.(v), value.(P_inj), value.(Q_inj), DATA[:branch_limit])

    return (
        objective   = objective_value(Central_Model),
        P_buy       = value.(P_buy),
        P_sell      = value.(P_sell),
        Pg_buy      = value.(Pg_buy),
        Pg_sell     = value.(Pg_sell),
        P_c         = value.(P_c),
        P_d         = value.(P_d),
        P_CES       = value.(P_CES),
        Pc_Grid     = value.(Pc_Grid),
        Pd_Grid     = value.(Pd_Grid),
        PCES_Grid   = value.(PCES_Grid),
        v           = value.(v),
        P_inj       = value.(P_inj),
        Q_inj       = value.(Q_inj),
    )
end


# ====================================================================
# STEP 2b: FITNESS FUNCTION (Called repeatedly by MOMSA)
#          Solves every day of the horizon and aggregates the results.
# ====================================================================
function evaluate_fitness(ces_sizes::Vector{Float64}, ces_locs::Vector{Float64})

    hour        = DATA[:hour]
    tot_hour    = DATA[:tot_hour]
    num_days    = DATA[:num_days]
    num_user    = DATA[:num_user]
    bus_sys     = DATA[:bus_sys]

    # 1. Map MOMSA inputs (Particle) to Grid CES Constraints (same for every day)
    num_ces = length(ces_sizes)
    CES_loc_matrix = zeros(Float64, num_ces, bus_sys)
    ces_bus = [Int(round(l)) for l in ces_locs]  # Ensure bus location is an integer
    for i in 1:num_ces
        CES_loc_matrix[i, ces_bus[i]] = 1.0
    end

    ub_CES_grid = ones(hour) * ces_sizes'
    ub_CEScd_grid = ones(hour) * (ces_sizes' ./ 3) # Max charge/discharge rate
    Pg_CES0 = ces_sizes .* 0.5 # Initial SOC is 50%

    # 2. Week-long containers, filled one day at a time
    P_buy_w     = zeros(tot_hour, num_user)
    P_sell_w    = zeros(tot_hour, num_user)
    Pg_buy_w    = zeros(tot_hour, num_user)
    Pg_sell_w   = zeros(tot_hour, num_user)
    P_c_w       = zeros(tot_hour, num_user)
    P_d_w       = zeros(tot_hour, num_user)
    P_CES_w     = zeros(tot_hour, num_user)
    Pc_Grid_w   = zeros(tot_hour, num_ces)
    Pd_Grid_w   = zeros(tot_hour, num_ces)
    PCES_Grid_w = zeros(tot_hour, num_ces)
    v_w         = zeros(tot_hour, bus_sys - 1)
    P_inj_w     = zeros(tot_hour, bus_sys - 1)
    Q_inj_w     = zeros(tot_hour, bus_sys - 1)
    obj_daily   = zeros(num_days)
    cost_daily  = zeros(num_days, num_user)     # ProfitCal costP2P, per day
    profit_daily = zeros(num_days)              # ProfitCal TNBearning, per day

    # 3. Solve day by day. Each day is SOC-cyclic, so the days are independent -
    #    one bad day does NOT invalidate the others, so keep going and record
    #    which days failed. A failed day leaves its slice at zero and is left
    #    out of the aggregates below.
    infeasible_days = Int[]

    for d in 1:num_days
        rows = set_day!(d)
        res = solve_day(CES_loc_matrix, ub_CES_grid, ub_CEScd_grid, Pg_CES0)

        if res === nothing
            push!(infeasible_days, d)
            @warn "Day $d is INFEASIBLE - continuing with the remaining days."
            continue
        end

        # ProfitCal is a single-day function: call it while DATA points at day d
        pros_cost, TNBearning = ProfitCal(res.Pg_buy, res.Pg_sell, res.P_buy, res.P_sell)
        cost_daily[d, :]   = Float64.(pros_cost)
        profit_daily[d]    = TNBearning

        obj_daily[d]        = res.objective
        P_buy_w[rows, :]    = res.P_buy
        P_sell_w[rows, :]   = res.P_sell
        Pg_buy_w[rows, :]   = res.Pg_buy
        Pg_sell_w[rows, :]  = res.Pg_sell
        P_c_w[rows, :]      = res.P_c
        P_d_w[rows, :]      = res.P_d
        P_CES_w[rows, :]    = res.P_CES
        Pc_Grid_w[rows, :]  = res.Pc_Grid
        Pd_Grid_w[rows, :]  = res.Pd_Grid
        PCES_Grid_w[rows,:] = res.PCES_Grid
        v_w[rows, :]        = res.v
        P_inj_w[rows, :]    = res.P_inj
        Q_inj_w[rows, :]    = res.Q_inj
    end

    # 4. Restore the full-week view of the cache
    set_day!(1)

    # 5. Replicate the C++ 'netload_branchlimit' logic over the whole week
    # Create a matrix of zeros for all buses: size [tot_hour, Bus]
    Charge_Discharge_CES = zeros(tot_hour, bus_sys)

    # Map each CES unit's net charge to its specific Bus Location
    for z in 1:num_ces
        # Net charge = Charge - Discharge
        Charge_Discharge_CES[:, ces_bus[z]] .+= Pc_Grid_w[:, z] .- Pd_Grid_w[:, z]
    end

    # 6. Return the Dictionary (weekly totals = sum of the daily values)
    #    Everything the solve produced is returned - same layout as CO_ROI_stage2.jl.
    solved = setdiff(1:num_days, infeasible_days)

    # The network summaries must ignore the zero rows a failed day leaves behind,
    # otherwise v_min reads 0.0 the moment any day fails.
    solved_rows = isempty(infeasible_days) ? collect(1:tot_hour) :
                  reduce(vcat, [collect(day_range(d)) for d in solved]; init = Int[])
    # 0.0 rather than NaN: JSON3 refuses to serialise NaN, which would blow up
    # the /evaluate response. Check "num_days_solved" before trusting these.
    v_s = isempty(solved_rows) ? [0.0] : v_w[solved_rows, :]
    P_s = isempty(solved_rows) ? zeros(1, bus_sys - 1) : P_inj_w[solved_rows, :]
    Q_s = isempty(solved_rows) ? zeros(1, bus_sys - 1) : Q_inj_w[solved_rows, :]

    return Dict(
        # 1 if ANY day failed. The arrays below still hold every day that solved,
        # with the failed days left as zeros - check "infeasible_days" to see which.
        "infeasible" => isempty(infeasible_days) ? 0 : 1,
        "infeasible_days" => infeasible_days,       # Vector of day indices, empty if all solved
        "num_days_solved" => length(solved),
        # --- scalars / summaries (sums over the SOLVED days only) ---
        "cost" => vec(sum(cost_daily[solved, :], dims=1)),  # Vector [num_user]
        "profit" => sum(profit_daily[solved]),              # Scalar
        "objective" => sum(obj_daily[solved]),              # Scalar, sum of the daily LP objectives
        "cost_daily" => cost_daily,                 # [num_days, num_user]
        "profit_daily" => profit_daily,             # Vector [num_days]
        "objective_daily" => obj_daily,             # Vector [num_days]
        "num_days" => num_days,
        "shape" => size(P_buy_w),                   # (tot_hour, num_user)
        "CES_shape" => size(Charge_Discharge_CES),  # (tot_hour, bus_sys)
        # --- grid CES operation ---
        "Charge_Discharge_CES" => Charge_Discharge_CES,   # [tot_hour, bus_sys]
        "CES_SOC_grid" => PCES_Grid_w,                    # [tot_hour, num_ces]
        "Pc_Grid" => Pc_Grid_w,                           # [tot_hour, num_ces]
        "Pd_Grid" => Pd_Grid_w,                           # [tot_hour, num_ces]
        "ces_sizes" => ces_sizes,                         # this particle's fleet
        "ces_locs" => ces_bus,                            # bus indices (rounded)
        # --- prosumer CES (+ve = charging, -ve = discharging) ---
        "Charge_Discharge_user" => P_c_w .- P_d_w,        # [tot_hour, num_user]
        "P_c" => P_c_w,
        "P_d" => P_d_w,
        "P_CES" => P_CES_w,
        # --- trading ---
        "P2P_buy" => P_buy_w,
        "P2P_sell" => P_sell_w,
        "Grid_buy" => Pg_buy_w,
        "Grid_sell" => Pg_sell_w,
        # --- network ---
        "voltage" => v_w,                                        # [tot_hour, bus_sys-1]
        "P_inj" => P_inj_w,                                      # [tot_hour, bus_sys-1]
        "Q_inj" => Q_inj_w,                                      # [tot_hour, bus_sys-1]
        # summaries below cover the SOLVED days only (a failed day is all zeros)
        "v_min" => minimum(v_s),
        "v_max" => maximum(v_s),
        "branch_P_max" => vec(maximum(abs.(P_s), dims=1)),       # [bus_sys-1]
        "branch_Q_max" => vec(maximum(abs.(Q_s), dims=1)),       # [bus_sys-1]
        "branch_limit" => DATA[:branch_limit],                   # [num_branch]
        # Needed to recover line loss from the LinDistFlow solution:
        #   loss_pu = r * (P_pu^2 + Q_pu^2) / v      (P_pu = P_inj / S_base)
        "branch_r" => diag(DATA[:D_r]),                          # [bus_sys-1] per-unit R
        "branch_x" => diag(DATA[:D_x]),                          # [bus_sys-1] per-unit X
        "S_base" => S_BASE,                                      # kVA
        # --- raw inputs (full week) ---
        "load" => DATA[:raw_load_full],
        "solar" => DATA[:solar_full],
        "pros_solar" => DATA[:pros_solar],
    )
end

end # End of Module
