# ====================================================================
# SANITY TEST SCRIPT  -  Stage 1 on WEEK-AHEAD data (CO_ROI_stage1.jl)
# Run via terminal: julia --project=. test/CO_test_stage1.jl
# ====================================================================

# 1. Include and load your module
println("Loading Module...")
# include("../subproblems/CO_Placement_LDF.jl")   # day-ahead placement
# include("../subproblems/CO_Placement_ptdf.jl")  # day-ahead placement (PTDF)
include("../subproblems/CO_ROI_stage1.jl")
using .Centralized_CES_Model, CSV, DataFrames

const HOUR_PER_DAY = 48

# Rows of the week-long result matrices belonging to day `d`
day_rows(d) = ((d - 1) * HOUR_PER_DAY + 1):(d * HOUR_PER_DAY)

# --------------------------------------------------------------------
# SCALERS - equivalent to editing LoadScaler / SolarScaler in setup_data,
# but applied here so neither the CSVs nor CO_ROI_stage1.jl need touching.
#
# The ROI_7days load is network-infeasible at full scale: with NO CES at all the
# voltage bottoms out at ~0.82 pu against the 0.95 pu limit, at 335 of 336 steps.
# Leave both at 1.0 for the real data; LOAD_SCALE ~0.2 makes the week solve.
# --------------------------------------------------------------------
const LOAD_SCALE  = 0.45
const SOLAR_SCALE = 1.15

# Re-derives everything setup_data builds from the raw load and solar matrices.
# MUST be called immediately after setup_data, which reloads both at scale 1 -
# it rebuilds from the cached arrays, so calling it twice would compound.
function apply_scalers!(load_s, solar_s)
    (load_s == 1.0 && solar_s == 1.0) && return
    D = Centralized_CES_Model.DATA
    bus_sys  = D[:bus_sys]
    num_user = D[:num_user]
    hour     = D[:hour]

    # 1. Scale the two raw inputs independently
    power_consumption = D[:raw_load_full] .* load_s
    solar             = D[:solar_full]    .* solar_s

    # 2. Rebuild net load and its bus projection (mirrors setup_data step 4)
    loc_prosumer = zeros(num_user, bus_sys)
    for i in 1:num_user
        loc_prosumer[i, i+1] = 1
    end
    D[:raw_load_full]   = power_consumption
    D[:solar_full]      = solar
    D[:P_load_full]     = power_consumption .- solar
    D[:P_load_bus_full] = D[:P_load_full] * loc_prosumer

    # 3. Rebuild the prosumer CES limits (mirrors setup_data step 7 - BatteryCap
    #    is derived from maximum(solar), so SOLAR_SCALE moves it too)
    BatteryCap = Int(ceil(2 * maximum(solar)))
    D[:ub_CES]  = BatteryCap * ones(hour, num_user)
    D[:lb_CES]  = zeros(hour, num_user)
    D[:ub_CESc] = (BatteryCap / 3) * ones(hour, num_user)
    D[:ub_CESd] = (BatteryCap / 3) * ones(hour, num_user)
    D[:P_CES0]  = (BatteryCap / 2) * ones(num_user)

    Centralized_CES_Model.set_day!(1)   # re-point the day-scoped keys
    println("[info] LOAD_SCALE = ", load_s, ", SOLAR_SCALE = ", solar_s,
            " -> Battery Capacity now ", BatteryCap, " kWh")
end

function run_test(bus_sys, ces_config)
    # 3. Run the setup_data function (caches data into DATA Dict)
    # NOTE: CO_ROI_stage1.jl asserts bus_sys == 33 - the 7-day CSVs only exist
    # for the 33-bus system.
    println("\n=== 1. Testing setup_data() ===")
    @time Centralized_CES_Model.setup_data(bus_sys)
    apply_scalers!(LOAD_SCALE, SOLAR_SCALE)

    # 4. Define dummy test parameters for the CES units
    # Ensure they are Float64 vectors as expected by evaluate_fitness
    # Example: 2 CES units -> 50kW at Bus 15, and 100kW at Bus 45.
    to_vector(x) = x isa AbstractVector ? Vector{Float64}(x) : Float64[x]

    ces_sizes = to_vector(ces_config["ces_sizes"])
    ces_locs  = to_vector(ces_config["ces_locs"])

    # evaluate_fitness indexes CES_loc_matrix by bus without a bounds check, so
    # catch an out-of-range location here instead of as a BoundsError.
    bad = findall(l -> !(2 <= round(Int, l) <= bus_sys), ces_locs)
    isempty(bad) || error("CES locations $(ces_locs[bad]) are outside 2:$(bus_sys).")
    length(ces_sizes) == length(ces_locs) || error("ces_sizes and ces_locs must have the same length.")

    # 5. Run the optimization function
    println("\n=== 2. Testing evaluate_fitness() ===")
    println("Inputs -> Sizes: ", ces_sizes, " | Locations: ", ces_locs)

    # We use @time to see exactly how long Gurobi takes to build and solve.
    # This is now 7 LPs (one per day), not 1.
    t_fitness = @elapsed results = Centralized_CES_Model.evaluate_fitness(ces_sizes, ces_locs)

    # 6. Display Output gracefully
    println("\n=== 3. Optimization Results ===")
    println("Evaluation Time: ", round(t_fitness, digits=4), " seconds")
    results["t_fitness"] = t_fitness  # Store the evaluation time in the results dictionary

    bad      = results["infeasible_days"]
    n_solved = results["num_days_solved"]
    tot_hour = results["shape"][1]
    num_days = tot_hour ÷ HOUR_PER_DAY

    if isempty(bad)
        println("Status:        SUCCESS (OPTIMAL) - all ", num_days, " days solved")
    elseif n_solved == 0
        println("Status:        FAILED (INFEASIBLE) - every day failed")
    else
        println("Status:        PARTIAL - ", n_solved, " of ", num_days, " days solved")
    end

    if !isempty(bad)
        println("Infeasible days: ", bad)
        println("Check if the sizes are too large for the branch limits.")
        if LOAD_SCALE == 1.0
            println("Note: at LOAD_SCALE = 1.0 the ROI_7days data is infeasible on its own -")
            println("      voltage reaches ~0.82 pu vs the 0.95 limit even with no CES.")
            println("      Settle LoadScaler / S_base / the voltage bound, or set LOAD_SCALE ~0.2 here.")
        end
    end

    if n_solved > 0
        # cost is a vector of 32 users, summed for the total system cost.
        # cost / profit / objective are sums over the SOLVED days only.
        total_cost = sum(results["cost"])

        println("Horizon:       ", tot_hour, " steps = ", num_days, " day(s)")
        println("Total Cost:    ", round(total_cost, digits=4), "   (", n_solved, " solved day(s))")
        println("Total Profit:  ", round(results["profit"], digits=4), "   (", n_solved, " solved day(s))")
        println("Per-day avg:   cost ", round(total_cost / n_solved, digits=4),
                " | profit ", round(results["profit"] / n_solved, digits=4))
        println("Time per day:  ", round(t_fitness / num_days, digits=4), " seconds")
        println("CES Matrix:    ", results["CES_shape"][1], " hours x ", results["CES_shape"][2], " buses")
    end
    return results
end

# Execute the test
bus_sys = 33    # CO_ROI_stage1.jl only supports 33 (7-day data availability)
moo = ["MOPSO", "MOLA", "MOMSA"]
moo_id = 3

# NOTE: the configurations below are 69-bus results and are out of range for the
# 33-bus week data. They are overridden just after, as in the original script.
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
ces_locs = [18, 22, 25, 33, 6, 10]   
ces_sizes = [400, 400, 400, 400, 400, 400]
ces_config = Dict("ces_sizes" => ces_sizes, "ces_locs" => ces_locs)
results = run_test(bus_sys, ces_config)

# ====================================================================
# CONFIGURATION EXTRACTION
# This section will extract the configuration of the congested scenarios
# including Total Load, Solar, and Power flow related data.
# ====================================================================
# The week-ahead module already hands back the raw inputs, so there is no need
# to re-read the CSVs the way the day-ahead version of this script did.
# Both are [Hour, Prosumer] = [336, 32], covering the whole week.
total_load  = sum(results["load"])
total_solar = sum(results["solar"])
tot_hour    = results["shape"][1]
num_days    = tot_hour ÷ HOUR_PER_DAY

println("\n=== 4. Load & Solar Summary ===")
println("Prosumers with solar : ", results["pros_solar"])
println("Total Load (MW):     ", round(total_load / 1000, digits=2),
        "   (per day ", round(total_load / 1000 / num_days, digits=2), ")")
println("Total Solar (MW):    ", round(total_solar / 1000, digits=2),
        "   (per day ", round(total_solar / 1000 / num_days, digits=2), ")")

# ---------------------------------------------------------------------
# CONGESTION SUMMARY
# NOTE: the branch and voltage limits are commented out in CO_ROI_stage1.jl,
# so the numbers below are the UNCONSTRAINED network state - exactly what you
# want to see when sizing the congestion problem.
# ---------------------------------------------------------------------
# An infeasible day leaves its 48 rows at zero, which would drag minimum(volt)
# down to 0. Keep only the rows belonging to days that actually solved.
solved_rows = collect(1:tot_hour)
for d in results["infeasible_days"]
    setdiff!(solved_rows, day_rows(d))
end

branch_limit = results["branch_limit"]              # [Branch] kW
P_inj = results["P_inj"][solved_rows, :]            # [Hour, Branch] active branch flow
Q_inj = results["Q_inj"][solved_rows, :]            # [Hour, Branch] reactive branch flow
volt  = results["voltage"][solved_rows, :]          # [Hour, Bus 2..N] p.u.

P_peak = vec(maximum(abs.(P_inj), dims=1))
Q_peak = vec(maximum(abs.(Q_inj), dims=1))
util   = P_peak ./ branch_limit            # 1.0 = exactly at the limit
over   = findall(util .> 1.0)

println("\n=== 5. Congestion Summary ===")
println("Branches over limit : ", length(over), " of ", length(branch_limit))
for b in sort(over, by = i -> -util[i])
    println("  Branch ", lpad(b, 2), " : ", lpad(round(P_peak[b], digits=1), 9), " kW vs ",
            lpad(round(branch_limit[b], digits=1), 8), " kW limit  (",
            round(util[b] * 100, digits=1), "% , exceed ",
            round(P_peak[b] - branch_limit[b], digits=1), " kW)")
end
worst_b = argmax(util)
println("Worst branch        : ", worst_b, " at ", round(util[worst_b] * 100, digits=1), "% of limit")

v_low  = count(<(0.95), volt)
v_high = count(>(1.05), volt)
println("Voltage range       : ", round(minimum(volt), digits=4), " .. ", round(maximum(volt), digits=4), " p.u.")
println("Voltage violations  : ", v_low, " below 0.95, ", v_high, " above 1.05, of ", length(volt), " entries")

# 6. Computational time average
# time_avg = 0

# for i in 1:10
#     results = run_test(bus_sys, ces_config)
#     global time_avg += results["t_fitness"]
# end

# time_avg /= 10
# println("\n=== 6. Computational Time ===")
# println("Average Time (s), whole week : ", round(time_avg, digits=2))
# println("Average Time (s), per day    : ", round(time_avg / 7, digits=2))

# ====================================================================
# 6. CONGESTION PLOTS
#    Branch power flow and voltage, with the limits drawn as reference lines.
# ====================================================================
using Plots, Plots.PlotMeasures

const PLOT_DIR = "D:/Jacky/Python/ADMM_P2P_Python/test/plots"
# Margins below stop the axis labels being clipped

function congestion_plots(results; save_dir = PLOT_DIR)
    # Drop the rows of any day that failed to solve - they are all zeros
    rows = collect(1:results["shape"][1])
    for d in results["infeasible_days"]
        setdiff!(rows, day_rows(d))
    end
    isempty(rows) && (println("\nNo solved days - nothing to plot."); return Dict())

    P_br = results["P_inj"][rows, :]     # [Hour, Branch] kW
    Q_br = results["Q_inj"][rows, :]     # [Hour, Branch] kVAr
    v    = results["voltage"][rows, :]   # [Hour, Bus 2..N] p.u.
    lim  = results["branch_limit"]       # [Branch] kW
    nbHour, nbBranch = size(P_br)
    nbBus = size(v, 2)

    P_peak = vec(maximum(abs.(P_br), dims=1))
    Q_peak = vec(maximum(abs.(Q_br), dims=1))
    util   = P_peak ./ lim

    # --- 1. Peak branch flow vs the limit -----------------------------
    p1 = plot(1:nbBranch, P_peak, label="max |P| over horizon", lw=2,
              marker=:circle, ms=3, mc=:steelblue, lc=:steelblue,
              xlabel="Branch", ylabel="Active Power (kW)",
              title="Peak Branch Active Power vs Limit",
              size=(900, 450), left_margin=8mm, bottom_margin=8mm, right_margin=5mm, top_margin=3mm, legend=:topright)
    plot!(p1, 1:nbBranch, lim, label="Branch Limit", ls=:dash, lc=:red, lw=2)
    over = findall(util .> 1.0)
    isempty(over) || scatter!(p1, over, P_peak[over], label="Over limit", mc=:red, ms=7)

    # --- 2. Peak reactive flow vs the same limit ----------------------
    p2 = plot(1:nbBranch, Q_peak, label="max |Q| over horizon", lw=2,
              marker=:circle, ms=3, mc=:seagreen, lc=:seagreen,
              xlabel="Branch", ylabel="Reactive Power (kVAr)",
              title="Peak Branch Reactive Power vs Limit",
              size=(900, 450), left_margin=8mm, bottom_margin=8mm, right_margin=5mm, top_margin=3mm, legend=:topright)
    plot!(p2, 1:nbBranch, lim, label="Branch Limit", ls=:dash, lc=:red, lw=2)

    # --- 3. Branch loading over time, normalised so one line serves all
    p3 = plot(xlabel="Time step (half-hourly)", ylabel="|P| / Branch Limit",
              title="Branch Loading over the Horizon",
              size=(900, 450), left_margin=8mm, bottom_margin=8mm, right_margin=5mm, top_margin=3mm, legend=:topright)
    for b in 1:nbBranch
        plot!(p3, 1:nbHour, abs.(P_br[:, b]) ./ lim[b],
              lc=:grey70, lw=0.7, label="")
    end
    # redraw the three worst on top so they are readable
    for b in sortperm(util, rev=true)[1:min(3, nbBranch)]
        plot!(p3, 1:nbHour, abs.(P_br[:, b]) ./ lim[b], lw=1.8,
              label="Branch $b ($(round(util[b]*100, digits=0))%)")
    end
    hline!(p3, [1.0], ls=:dash, lc=:red, lw=2, label="Branch Limit")
    vline!(p3, [48*d for d in 1:(nbHour ÷ 48 - 1)], ls=:dot, lc=:grey40, lw=1, label="")

    # --- 4. Voltage over time, every bus ------------------------------
    p4 = plot(xlabel="Time step (half-hourly)", ylabel="Voltage (p.u.)",
              title="Bus Voltage over the Horizon",
              size=(900, 450), left_margin=8mm, bottom_margin=8mm, right_margin=5mm, top_margin=3mm, legend=:bottomright)
    for i in 1:nbBus
        plot!(p4, 1:nbHour, v[:, i], lc=:grey70, lw=0.7, label="")
    end
    worst_bus = argmin(vec(minimum(v, dims=1)))
    plot!(p4, 1:nbHour, v[:, worst_bus], lc=:steelblue, lw=1.8,
          label="Bus $(worst_bus+1) (lowest)")
    hline!(p4, [0.95, 1.05], ls=:dash, lc=:red, lw=2, label="Limits (0.95 / 1.05)")
    vline!(p4, [48*d for d in 1:(nbHour ÷ 48 - 1)], ls=:dot, lc=:grey40, lw=1, label="")

    # --- 5. Voltage envelope per bus ----------------------------------
    vmin = vec(minimum(v, dims=1)); vmax = vec(maximum(v, dims=1))
    p5 = plot(2:(nbBus+1), vmin, label="min over horizon", lw=2,
              marker=:circle, ms=3, lc=:steelblue, mc=:steelblue,
              xlabel="Bus", ylabel="Voltage (p.u.)",
              title="Voltage Envelope per Bus",
              size=(900, 450), left_margin=8mm, bottom_margin=8mm, right_margin=5mm, top_margin=3mm, legend=:bottomleft)
    plot!(p5, 2:(nbBus+1), vmax, label="max over horizon", lw=2,
          marker=:circle, ms=3, lc=:darkorange, mc=:darkorange)
    hline!(p5, [0.95, 1.05], ls=:dash, lc=:red, lw=2, label="Limits (0.95 / 1.05)")

    plots = Dict("branch_P_peak" => p1, "branch_Q_peak" => p2,
                 "branch_loading" => p3, "voltage_time" => p4,
                 "voltage_envelope" => p5)

    if save_dir !== nothing
        isdir(save_dir) || mkpath(save_dir)
        for (name, p) in plots
            savefig(p, joinpath(save_dir, "$(name).png"))
        end
        println("\nPlots saved to: ", save_dir)
    end
    foreach(display, (p1, p2, p3, p4, p5))
    return plots
end

plots = congestion_plots(results)

# 7. Save trading outcome
P_buy = results["P2P_buy"]
P_sell = results["P2P_sell"]
Pg_buy = results["Grid_buy"]
Pg_sell = results["Grid_sell"]

save_path = "D:/Jacky/Data Output/CES size and loc/Individual Scenario Outcome/$(bus_sys)bus_week/"
isdir(save_path) || mkpath(save_path)

# CSV.write("$(save_path)Grid_buy.csv", DataFrame(Pg_buy, :auto))
# CSV.write("$(save_path)Grid_sell.csv", DataFrame(Pg_sell, :auto))
# CSV.write("$(save_path)P2P_buy.csv", DataFrame(P_buy, :auto))
# CSV.write("$(save_path)P2P_sell.csv", DataFrame(P_sell, :auto))
CSV.write("$(save_path)Charge_Discharge_CES.csv", DataFrame(results["Charge_Discharge_CES"], :auto))
