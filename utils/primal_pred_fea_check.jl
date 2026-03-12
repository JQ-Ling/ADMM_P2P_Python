using JuMP, CSV, DataFrames, Gurobi, Random, Plots, Printf, Dates, NPZ, JSON

################################################################################################
# This file is used to check the predictions' feasibility by using the direct model formulation
################################################################################################

####### Current version to check: ADMM_fcn_TC1_LP_PrioGO
include("../subproblems/feasibility_checks/ADMM_fcn_TC1_LP_PrioGO checking purpose.jl")

dataset = "D:/Jacky/Data Output/ADMM_P2P/Database/LP_PrioGO_test_20_OldSame"
config_name = "config"
config_path = joinpath(dataset, config_name*".json")
config = JSON.parsefile(config_path)
sce_start = config["sce_start"] 
sce_end = config["sce_end"]
tot_sce = sce_end - config["sce_start"] + 1

primal_pred_location = joinpath(dataset, "predictions", "primal_pred_post.npy")
primal_pred = npzread(primal_pred_location)
dual_pred_location = joinpath(dataset, "predictions", "dual_pred.npy")
dual_pred = npzread(dual_pred_location)

######### Scenario data preparation
char_data_location_1 = "D:/Jacky/Julia-vscode/ADMM_P2P/Power Consumption_33_bus.csv"
power_consumption_data = (CSV.File(char_data_location_1) |> DataFrame)
LoadScaler = 1
power_consumption = Matrix(power_consumption_data) ./2 .* LoadScaler

nb_prosumer = size(power_consumption_data, 2)  # number of prosumers
nb_hour = size(power_consumption_data, 1)  # time
hour = nb_hour
num_user = nb_prosumer

char_data_location_2 = "D:/Jacky/Julia-vscode/ADMM_P2P/Solar_interpolated_6000.csv"
net_load_data = CSV.File(char_data_location_2, header=true) |> DataFrame

SolarScaler = 1
interpolated_solar_scenarios = Matrix(net_load_data) .* SolarScaler

# 1. Read the CSV into a DataFrame
df_p = CSV.read(joinpath(dataset, "Param_Prosumer.csv"), DataFrame)
df_g = CSV.read(joinpath(dataset, "Param_Grid.csv"), DataFrame)

# 2. Initialize the Dictionary
# We use Symbol for keys so you can access them like Param[:ub_CES]
Param_Prosumer = Dict{Symbol, Any}()
Param_Grid = Dict{Symbol, Any}()

# 3. Loop through rows and parse the second column
for row in eachrow(df_p)
    key = Symbol(row.first)
    value_str = row.second
    
    try
        # Meta.parse converts the string into a Julia expression
        # eval() executes that expression to create the actual Array/Matrix
        Param_Prosumer[key] = eval(Meta.parse(value_str))
    catch e
        @warn "Could not parse value for $key. Storing as string instead."
        Param_Prosumer[key] = value_str
    end
end

for row in eachrow(df_g)
    key = Symbol(row.first)
    value_str = row.second
    
    try
        # Meta.parse converts the string into a Julia expression
        # eval() executes that expression to create the actual Array/Matrix
        Param_Grid[key] = eval(Meta.parse(value_str))
    catch e
        @warn "Could not parse value for $key. Storing as string instead."
        Param_Grid[key] = value_str
    end
end

###### feasibility check
termination_pros = []
termination_go = []
for sce in sce_start:sce_end
    Poutaux_optimal = primal_pred[sce,:,:]
    λ_optimal = dual_pred[sce,:,:]

    solar = interpolated_solar_scenarios[sce,:]
    nb_bus = Param_Grid[:num_bus]
    max_pros = nb_bus/3 # max prosumer in one bus for test case 3
    pros_solar = Int(ceil(nb_prosumer / 2))
    net_load = copy(power_consumption')
    net_load[pros_solar:end, :] .-= 1.5 * solar'

    Param_Prosumer[:load_demamd] = net_load'
    Param_Grid[:load_demamd] = net_load'

    for k in 1:num_user
        term_status = Subproblem_Prosumer(Param_Prosumer, Poutaux_optimal, k, λ_optimal, 1; check=true)
        push!(termination_pros, term_status)
    end
    term_status = Subproblem_Grid_Operator(Param_Grid, Poutaux_optimal, λ_optimal, 1; check=true)
    push!(termination_go, term_status)
end 
for sce in sce_start:sce_end
    println("Scenario $sce:")
    for k in 1:num_user
        if termination_pros[(sce-1)*num_user + k] == MOI.INFEASIBLE
            println("  Prosumer $k INFEASIBLE")
            continue
        end
        println("  Prosumer $k termination status: ", termination_pros[(sce-1)*num_user + k])
    end
    if termination_go[sce] == MOI.INFEASIBLE
        println("  Grid Operator INFEASIBLE")
        continue
    end
    println("  Grid Operator termination status: ", termination_go[sce])
    println("--------------------------------------------------")
    println()
end