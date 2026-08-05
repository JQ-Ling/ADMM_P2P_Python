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
#   ces_sizes / ces_locs are FIXED for the whole study - set them here once,
#   they are no longer arguments of evaluate_fitness.
function setup_data(bus_sys;
                    ces_sizes::Vector{Float64} = [500.0, 500.0],   # <-- CONFIRM these
                    ces_locs::Vector{Float64}  = [10.0, 25.0])     # <-- CONFIRM these
    println("\n*****************************************************")
    println("Initializing $(bus_sys)-bus Centralized Model Data...")
    println("Loading Data for a Week...")
    @assert bus_sys == 33 "Only 33-bus systems are supported."

    # 1. Basic Parameters
    hour = 48                   # Optimisation horizon of ONE day (half-hourly)
    LoadScaler  = 1
    SolarScaler = 1
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
    net_load_data = DataFrame(CSV.File("$week_path/Solar_7days.csv")) # multiply with nominal load, hence contain the PV for each bus
    solar = Matrix(net_load_data[:,2:end]) .* SolarScaler
    @assert size(solar) == size(power_consumption) "Load $(size(power_consumption)) and Solar $(size(solar)) must share the same [Hour, Prosumer] shape."

    # 3b. Split the horizon into whole days
    @assert tot_hour % hour == 0 "Data length ($tot_hour) is not a whole multiple of the daily horizon ($hour)."
    num_days = tot_hour ÷ hour
    DATA[:tot_hour] = tot_hour
    DATA[:num_days] = num_days

    # 4. Calculate Net Load & Prosumer Locations
    pros_solar = [18, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32] # Prosumer indices with solar panels
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
    # NOTE: the per-user capacity / charge / discharge limits are NO LONGER fixed
    # here - they are scenario inputs, built per call by build_scenario().
    DATA[:lb_CES]  = zeros(hour, num_user)
    DATA[:efficiency_CES] = 0.9
    DATA[:P2PTrade] = [16, 38]
    DATA[:beta_tnb] = 1.0

    # 8. FIXED Grid CES fleet (sizes and bus locations, constant for every call)
    @assert length(ces_sizes) == length(ces_locs) "ces_sizes and ces_locs must have the same length."
    num_ces = length(ces_sizes)
    ces_bus = [Int(round(l)) for l in ces_locs]     # Ensure bus location is an integer
    @assert all(2 .<= ces_bus .<= bus_sys) "CES bus locations must be within 2:$(bus_sys)."

    CES_loc_matrix = zeros(Float64, num_ces, bus_sys)
    for i in 1:num_ces
        CES_loc_matrix[i, ces_bus[i]] = 1.0
    end

    DATA[:ces_sizes]      = ces_sizes
    DATA[:ces_locs]       = ces_locs
    DATA[:ces_bus]        = ces_bus
    DATA[:num_ces]        = num_ces
    DATA[:CES_loc_matrix] = CES_loc_matrix
    DATA[:ub_CES_grid]    = ones(hour) * ces_sizes'          # [hour, num_ces]
    DATA[:ub_CEScd_grid]  = ones(hour) * (ces_sizes' ./ 3)   # Max charge/discharge rate
    DATA[:Pg_CES0]        = ces_sizes .* 0.5                 # Initial SOC is 50%

    set_day!(1)     # Start pointed at day 1

    println("Fixed CES fleet: sizes = ", ces_sizes, " kWh at buses ", ces_bus)
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
# STEP 2a: SCENARIO SETUP
#   Turns the caller's inputs into the per-step CES prices and the prosumer
#   battery limits. The same config is reused for all 7 days.
#
#   :subscription -> (priority::Real, sub_caps::Vector)
#         priority : one value replacing the old flat 0.005, applied to charge
#                    AND discharge, every step of every day.
#         sub_caps : capacity each user subscribes to [num_user]. Replaces the
#                    old fixed BatteryCap, so the per-user limits become
#                    input-dependent. Grid-side Pg_CES0 is untouched.
#
#   :usage        -> (cost_array::Vector)  6 values, C++ inputArray order:
#         [1] charge normal   [2] discharge normal    (steps 1:P2PTrade[1])
#         [3] charge P2P      [4] discharge P2P       (steps P2PTrade[1]+1 : P2PTrade[2]-1)
#         [5] charge close    [6] discharge close     (steps P2PTrade[2]:hour)
#         Users get NO individual capacity; only the aggregate is capped.
# ====================================================================
function build_scenario(scenario::Symbol, args...)
    hour     = DATA[:hour]
    num_user = DATA[:num_user]
    P2PTrade = DATA[:P2PTrade]

    if scenario == :subscription
        length(args) == 2 || error(":subscription expects (priority, sub_caps), got $(length(args)) argument(s).")
        priority, sub_caps_in = args
        caps = Float64.(collect(sub_caps_in))
        length(caps) == num_user || error("sub_caps must have $num_user entries, got $(length(caps)).")
        all(caps .>= 0) || error("sub_caps must be non-negative.")

        # Flat price over the whole horizon, charge and discharge alike
        cost_c = fill(Float64(priority), hour)
        cost_d = fill(Float64(priority), hour)

        # Per-user limits now follow the subscribed capacity
        return (name = :subscription,
                cost_c = cost_c, cost_d = cost_d,
                ub_CES  = ones(hour) * caps',
                ub_CESc = ones(hour) * (caps' ./ 3),
                ub_CESd = ones(hour) * (caps' ./ 3),
                P_CES0  = caps ./ 2,
                sub_caps = caps,
                per_user_caps = true)

    elseif scenario == :usage
        length(args) == 1 || error(":usage expects (cost_array,), got $(length(args)) argument(s).")
        ca = Float64.(collect(args[1]))
        length(ca) == 6 || error("usage cost_array must hold 6 values [c_normal, d_normal, c_p2p, d_p2p, c_close, d_close], got $(length(ca)).")

        # Period split mirrors the C++ (and the P2P trading window constraints)
        normal_p = 1:P2PTrade[1]                        # C++ t = 0..15
        p2p_p    = (P2PTrade[1] + 1):(P2PTrade[2] - 1)  # C++ t = 16..36
        close_p  = P2PTrade[2]:hour                     # C++ t = 37..47

        cost_c = zeros(hour); cost_d = zeros(hour)
        cost_c[normal_p] .= ca[1];  cost_d[normal_p] .= ca[2]
        cost_c[p2p_p]    .= ca[3];  cost_d[p2p_p]    .= ca[4]
        cost_c[close_p]  .= ca[5];  cost_d[close_p]  .= ca[6]

        # No individual capacity: limits are enforced on the SUM over users only
        return (name = :usage,
                cost_c = cost_c, cost_d = cost_d,
                ub_CES = nothing, ub_CESc = nothing, ub_CESd = nothing,
                P_CES0 = nothing, sub_caps = nothing,
                per_user_caps = false)
    else
        error("Unknown scenario :$scenario - expected :subscription or :usage.")
    end
end


# ====================================================================
# STEP 2b: SINGLE-DAY SOLVE (internal helper, one 48-step LP)
#          Operates on whichever day set_day! currently points at.
# ====================================================================
function solve_day(cfg)

    # 1. Retrieve Data from Cache (already sliced down to the current day)
    hour            = DATA[:hour]
    num_user        = DATA[:num_user]
    bus_sys         = DATA[:bus_sys]
    efficiency_CES  = DATA[:efficiency_CES]
    P2PTrade        = DATA[:P2PTrade]
    P_load          = DATA[:P_load]
    P_load_bus      = DATA[:P_load_bus]

    # Fixed CES fleet
    num_ces         = DATA[:num_ces]
    CES_loc_matrix  = DATA[:CES_loc_matrix]
    ub_CES_grid     = DATA[:ub_CES_grid]
    ub_CEScd_grid   = DATA[:ub_CEScd_grid]
    Pg_CES0         = DATA[:Pg_CES0]

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

    if cfg.per_user_caps
        # Subscription: every user is capped at the capacity they subscribed to
        @variable(Central_Model, 0 <= P_CES[i=1:hour, j=1:num_user] <= cfg.ub_CES[i, j])
        @variable(Central_Model, 0 <= P_c[i=1:hour, j=1:num_user] <= cfg.ub_CESc[i, j])
        @variable(Central_Model, 0 <= P_d[i=1:hour, j=1:num_user] <= cfg.ub_CESd[i, j])
    else
        # Usage: no individual ceiling, only the aggregate limits added below
        @variable(Central_Model, P_CES[1:hour, 1:num_user] >= 0)
        @variable(Central_Model, P_c[1:hour, 1:num_user] >= 0)
        @variable(Central_Model, P_d[1:hour, 1:num_user] >= 0)
    end

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
        # State equations and "cannot discharge more than is stored" hold in both
        # scenarios - they never reference a capacity ceiling.
        @constraint(Central_Model, [i in 1:hour-1],    P_d[i+1, u] .<= (P_CES[i, u] .- DATA[:lb_CES][i, u]) .* efficiency_CES)
        @constraint(Central_Model,                     P_d[1, u] .<= (P_CES[1, u] .- DATA[:lb_CES][1, u]) .* efficiency_CES)
        @constraint(Central_Model, [i in 1:hour-1],    P_CES[i+1, u] == P_CES[i, u] + (efficiency_CES * P_c[i, u]) - (P_d[i, u] / efficiency_CES))
        @constraint(Central_Model,                     P_CES[1, u] == P_CES[end, u] + (efficiency_CES * P_c[end, u]) - (P_d[end, u] / efficiency_CES))

        if cfg.per_user_caps
            # Subscription: headroom, C/D exclusivity and the 50% start are all
            # per user, driven by the subscribed capacity.
            @constraint(Central_Model, [i in 1:hour-1], P_c[i+1, u] .<= (cfg.ub_CES[i, u] .- P_CES[i, u]) ./ efficiency_CES)
            @constraint(Central_Model,                  P_c[1, u] .<= (cfg.ub_CES[1, u] .- P_CES[1, u]) ./ efficiency_CES)
            @constraint(Central_Model,                  P_CES[1, u] == cfg.P_CES0[u])
            # Guard the ratio: a user may subscribe 0 kWh, which would make it 0/0
            cd_ratio = [c > 0 ? d / c : 0.0 for (d, c) in zip(cfg.ub_CESd[:, u], cfg.ub_CESc[:, u])]
            @constraint(Central_Model,                  P_d[:, u] .<= cfg.ub_CESd[:, u] .- cd_ratio .* P_c[:, u])
        end
    end

    # Usage scenario: users share one pool. Nothing caps them individually - the
    # SUM of their charge, discharge and stored energy is held under the fixed
    # grid CES fleet, and the starting split is left free (the day is cyclic).
    if !cfg.per_user_caps
        agg_CES = vec(sum(ub_CES_grid, dims=2))     # total kWh across the fleet
        agg_cd  = vec(sum(ub_CEScd_grid, dims=2))   # total charge/discharge rate
        @constraint(Central_Model, [t in 1:hour], sum(P_CES[t, :]) <= agg_CES[t])
        @constraint(Central_Model, [t in 1:hour], sum(P_c[t, :])   <= agg_cd[t])
        @constraint(Central_Model, [t in 1:hour], sum(P_d[t, :])   <= agg_cd[t] - sum(P_c[t, :]))
        @constraint(Central_Model, [i in 1:hour-1], sum(P_c[i+1, :]) <= (agg_CES[i] - sum(P_CES[i, :])) / efficiency_CES)
        @constraint(Central_Model,                  sum(P_c[1, :])   <= (agg_CES[1] - sum(P_CES[1, :])) / efficiency_CES)
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
    # cost_c / cost_d are [hour] vectors, so they broadcast down each column
    # (one entry per time step, identical for all users and all 7 days).
    f_p2p = sum(P_buy .* DATA[:buy_priority]') + sum(P_sell .* DATA[:sell_priority]')
    f_grid_trade = sum(DATA[:beta_tnb] .* (Pg_buy .+ Pg_sell))
    f_ces_deg = sum(cfg.cost_c .* P_c)     + sum(cfg.cost_d .* P_d) +
                sum(cfg.cost_c .* Pc_Grid) + sum(cfg.cost_d .* Pd_Grid)

    @objective(Central_Model, Min, f_p2p + f_grid_trade + f_ces_deg)

    # --- OPTIMIZE AND RETURN ---
    optimize!(Central_Model)

    if termination_status(Central_Model) != MOI.OPTIMAL
        return nothing
    end

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
# STEP 2c: FITNESS FUNCTION (Called repeatedly by MOMSA)
#          Solves every day of the horizon and aggregates the results.
#
#   evaluate_fitness(:subscription, priority, sub_caps)
#   evaluate_fitness(:usage, cost_array)
#
#   The CES fleet (ces_sizes / ces_locs) is fixed in setup_data and is no
#   longer part of the particle.
# ====================================================================
function evaluate_fitness(scenario::Symbol, args...)

    tot_hour    = DATA[:tot_hour]
    num_days    = DATA[:num_days]
    num_user    = DATA[:num_user]
    bus_sys     = DATA[:bus_sys]
    num_ces     = DATA[:num_ces]
    ces_bus     = DATA[:ces_bus]

    # 1. Turn the MOMSA inputs (Particle) into CES prices and battery limits
    cfg = build_scenario(scenario, args...)

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

    # 3. Solve day by day. Each day is SOC-cyclic, so the days are independent.
    for d in 1:num_days
        rows = set_day!(d)
        res = solve_day(cfg)

        if res === nothing
            set_day!(1)
            return Dict("infeasible" => 1, "failed_day" => d, "scenario" => String(cfg.name))
        end

        # ProfitCal is a single-day function: call it while DATA points at day d
        pros_cost, TNBearning = ProfitCal(res.Pg_buy, res.Pg_sell, res.P_buy, res.P_sell)
        cost_daily[d, :]  = Float64.(pros_cost)
        profit_daily[d]   = TNBearning

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
        Charge_Discharge_CES[:, ces_bus[z]] .= Pc_Grid_w[:, z] .- Pd_Grid_w[:, z]
    end

    # 6. Return the Dictionary
    return Dict(
        "infeasible" => 0,
        "scenario" => String(cfg.name),
        # --- scalars / summaries (weekly = sum of the daily values) ---
        "cost" => vec(sum(cost_daily, dims=1)),     # Vector [num_user], whole week
        "profit" => sum(profit_daily),              # Scalar, whole week
        "objective" => sum(obj_daily),              # Scalar, sum of the daily LP objectives
        "cost_daily" => cost_daily,                 # [num_days, num_user]
        "profit_daily" => profit_daily,             # Vector [num_days]
        "objective_daily" => obj_daily,             # Vector [num_days]
        "num_days" => num_days,
        "shape" => size(P_buy_w),                   # (tot_hour, num_user)
        "CES_shape" => size(Charge_Discharge_CES),  # (tot_hour, bus_sys)
        # --- grid CES operation ---
        "Charge_Discharge_CES" => Charge_Discharge_CES,   # [tot_hour, bus_sys]
        "CES_SOC_grid" => PCES_Grid_w,                    # [tot_hour, num_ces]
        "ces_sizes" => DATA[:ces_sizes],                  # fixed fleet, for SOC normalisation
        "ces_locs" => DATA[:ces_bus],                     # fixed fleet bus indices
        # --- prosumer CES usage (+ve = charging, -ve = discharging) ---
        # MATLAB prices this per time step in the :usage scenario
        "Charge_Discharge_user" => P_c_w .- P_d_w,        # [tot_hour, num_user]
        # --- trading (uncomment what MOMSA actually needs) ---
        # "P2P_buy" => P_buy_w,
        # "P2P_sell" => P_sell_w,
        # "Grid_buy" => Pg_buy_w,
        # "Grid_sell" => Pg_sell_w,
        # --- prosumer CES ---
        # "P_c" => P_c_w,
        # "P_d" => P_d_w,
        # "P_CES" => P_CES_w,
        # --- network ---
        # "voltage" => v_w,
        # "P_inj" => P_inj_w,
        # "Q_inj" => Q_inj_w,
        "v_min" => minimum(v_w),
        "v_max" => maximum(v_w),
        "branch_P_max" => vec(maximum(abs.(P_inj_w), dims=1)),   # [bus_sys-1]
        "branch_Q_max" => vec(maximum(abs.(Q_inj_w), dims=1)),   # [bus_sys-1]
        # --- raw inputs (full week) ---
        "load" => DATA[:raw_load_full],
        "solar" => DATA[:solar_full],
        "pros_solar" => DATA[:pros_solar],
    )
end

end # End of Module
