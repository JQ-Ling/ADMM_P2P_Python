using JuMP, CSV, DataFrames, Gurobi, Random, Plots, Printf, Dates, NPZ, LinearAlgebra, XLSX
# using PCHIPInterpolation
# using Statisticspower
# using StatsBase

# Includes
include("../subproblems/Analysis/PrioGO_proximal_DistFlow_AdaptiveCES_4Dec.jl")
include("../utils/Price_fcn.jl")
include("../utils/Data Saving.jl")
# include("AI_pred/Prediction evaluation/Sol_feasibility.jl")
# include("AI_pred/Prediction evaluation/KKT_checking.jl")

# === Step #1: Load Data ===
bus_sys = 69

# (1) Power Consumption.
# PowerConsumption[Prosumer][Hour]
char_data_location_1 = "D:/Jacky/Julia-vscode/ADMM_P2P/Power Consumption_$(bus_sys)_bus.csv"
power_consumption_data = (CSV.File(char_data_location_1) |> DataFrame)
LoadScaler = 10
power_consumption = Matrix(power_consumption_data) ./2 .* LoadScaler
power_consumption[:,26] *= 2
power_consumption[:,34] *= 2
power_consumption[:,51] *= 2

hour, num_user = size(power_consumption_data)

println("No. Prosumer = ", num_user)
println("No. Time Step = ", hour)

# (2) Solar
# Solar[Hour]
char_data_location_2 = "D:/Jacky/Julia-vscode/ADMM_P2P/Solar_interpolated_6000.csv"
net_load_data = CSV.File(char_data_location_2, header=true) |> DataFrame

SolarScaler = 10
# SolarScaler = 1.5
interpolated_solar_scenarios = Matrix(net_load_data) .* SolarScaler

# (6) PTDF
ptdf_file_location = "D:/Jacky/Julia-vscode/ADMM_P2P/radial$(bus_sys)bus_PTDF.csv"
ptdf_data = CSV.File(ptdf_file_location, header=false) |> DataFrame

nb_bus = size(ptdf_data, 2)
nb_branch = size(ptdf_data, 1)
ptdf = Matrix(ptdf_data)

# (7) Branch limit
BranchLimit_file_location = "D:/Jacky/Julia-vscode/ADMM_P2P/$(bus_sys)_bus_limit_data.csv"
BranchLimit_data = CSV.File(BranchLimit_file_location, header=true) |> DataFrame

BranchLimit = BranchLimit_data[!, 1] .* 1000

# (8) CES configurations - Number, Locations and Capacity
ces_loc = [2]
num_ces = length(ces_loc)
CES_loc_matrix = zeros(Float64, num_ces, nb_bus)
for i = 1:num_ces
    loc = ces_loc[i]
    CES_loc_matrix[i, loc] = 1.0
end

# (9) LinDistFlow Parameters
xf = XLSX.readxlsx("D:/Jacky/Python/ADMM_P2P_Python/data/IEEE$(bus_sys)_LinDistFlow_Matrices_PU.xlsx")
r_pu = xf["Vectors_PU"][2:end,3]
x_pu = xf["Vectors_PU"][2:end,4]

# 3. Read the A Matrix and a_0 vector
A_matrix = xf["A_Matrix"][2:end,2:end]    # Read the specific range
a_0 = xf["Vectors_PU"][2:end, 2]        # Read a_0 column from a "Vectors" sheet

# 4. Convert to proper Julia types for Math
A_matrix = Float64.(A_matrix)
a_0 = Float64.(a_0)
D_r = Diagonal(Float64.(vec(r_pu)))
D_x = Diagonal(Float64.(vec(x_pu)))

########################################################################################################

# set your starting scenario and ending scenario number to generate
sce_start, sce_end = 1, 1

tc2, tc3 = 1, 2
count_tc2, count_tc3 = 999, 1
execution_times, optimal_num, infeasible_sce = [], [], []
infeasible = 0

# Preallocation (kept compact for readability)
train_dual = zeros(5, 4 * hour, num_user, 51)
train_primal = zeros(5, 4 * hour, num_user, 51)
train_P_decision = zeros(5, 8 * hour, num_user, 51)
loc_prosumer_all = zeros(num_user, nb_bus, 5)
loc_pros_solar_all = zeros(5, num_user)
train_primal_error = fill(NaN, 5, 5000)
train_primal_residual = fill(NaN, 5, 5000)
train_dual_error = fill(NaN, 5, 5000)
train_dual_residual = fill(NaN, 5, 5000)
train_obj = fill(NaN, 5, 5000)
buy_priority_all = zeros(num_user, hour, 5)
sell_priority_all = zeros(num_user, hour, 5)
prosumer_cost_all = zeros(224, 1000)
TNBearning_all = zeros(5, 1000)

@time for sce in sce_start:sce_end
    elapsed_time = @elapsed begin

        global Param_Prosumer, Param_Grid, Pout_all, λ, Pout, Pout_aux, cost, total_cost, primal_error, dual_error,
        Prosumer_decision, Grid_decision, iteration_num, rho_u, net_load, primal_residual,
        dual_residual, rhov, loc_prosumer, loc_CES, tc2, tc3, count_tc2, count_tc3, obj_all, P_decision_all, Pout_aux_all,
        infeasible_sce, infeasible, obj_g, obj_p, Grid_CES_all, ctp, ctd, subproblem_times, ui_all

        # === Scenario Initialization ===
        solar = interpolated_solar_scenarios[sce, :]
        max_pros = nb_bus / 3
        pros_solar = Int(ceil(num_user / 2))
        net_load = copy(power_consumption')
        net_load[pros_solar:end, :] .-= 1.5 * solar'

        loc_prosumer = zeros(num_user, nb_bus)
        for i in 1:num_user
            loc_prosumer[i, i+1] = 1
        end

        # Test Case 2: slowly increase the number of prosumers 
        # one bus one prosumers
        if tc2 <= num_user && count_tc2 == 0
            loc_prosumer = zeros(num_user, nb_bus)
            for i in 1:tc2
                loc_prosumer[i, i+1] = 1
            end
            tc2 += 1
        elseif count_tc2 ==0
            tc2 = 1
            count_tc2 = 1 # disable test case 2
            count_tc3 = 0 # enable test case 3
        end

        # Test Case 3: Test Case 1 + 2
        # only one randomly choose bus will have multiple prosumers
        if tc3 <= max_pros && count_tc3 == 0
            # random_prosumers = sample(1:num_user, Int(rand(max_pros:num_user)), replace=false)
            rand_pros_bus = sample(1:num_user, tc3, replace=false)
            random_bus = sample(rand_pros_bus, 1, replace=false) # start from bus 2 to ensure bus 1 dun have any load
            loc_prosumer = zeros(num_user, nb_bus)
            for i in 1:num_user
                # if sum(i .== random_prosumers) != 0
                #     if sum(i .== rand_pros_bus) != 0
                #         loc_prosumer[i,random_bus.+1] .= 1
                #     else
                #         loc_prosumer[i,i+1] = 1
                #     end
                # end
                if sum(i .== rand_pros_bus) != 0
                    loc_prosumer[i, random_bus.+1] .= 1
                else
                    loc_prosumer[i, i+1] = 1
                end
            end
            tc3 += 1
            if tc3 > max_pros && count_tc3 == 0
                tc3 = 2
                count_tc2 = 0 # enable test case 2
                count_tc3 = 1 # disable test case 3
            end
        end

        loc_prosumer_all[:, :, sce - sce_start + 1] = loc_prosumer
        # num_user_set = [k for k in 1:num_user if sum(loc_prosumer[k, :]) == 1]
        loc_pros_solar = zeros(num_user)
        loc_pros_solar = [1 * (sum(loc_prosumer[k, :]) == 1 && k >= pros_solar) for k in 1:num_user]
        loc_pros_solar_all[sce - sce_start + 1, :] = loc_pros_solar

        # (4) Bidding Price and Bidding Priority
        # (4.1) TNB Cost
        tnb_cost = [0.5443, 0.15]

        # (2.2) Bidding Cost
        total_excess = zeros(hour)
        total_deficiency = zeros(hour)

        for i in 1:hour
            total_excess[i] = sum(net_load[j, i] < 0 ? -net_load[j, i] : 0 for j in 1:num_user)
            total_deficiency[i] = sum(net_load[j, i] > 0 ? net_load[j, i] : 0 for j in 1:num_user)
        end
        
        ## === Preset Priority ===
        ####################################################################################################
        # BuyBP[Prosumer][Time Step]   SellBP[Prosumer][Time Step]
        # BuyPriority[Prosumer][Time Step]   SellPriority[Prosumer][Time Step]
        bpp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/buy_price_$(bus_sys).csv"
        spp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/sell_price_$(bus_sys).csv"
        bp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/buy_priority_$(bus_sys).csv"
        sp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/sell_priority_$(bus_sys).csv"

        buy_bp = Matrix(CSV.File(bpp_file, header=false) |> DataFrame)
        sell_bp = Matrix(CSV.File(spp_file, header=false) |> DataFrame)
        buy_priority = Matrix(CSV.File(bp_file, header=false) |> DataFrame)
        sell_priority = Matrix(CSV.File(sp_file, header=false) |> DataFrame)

        # buy_priority_all[:, :, sce - sce_start + 1] = buy_priority
        # sell_priority_all[:, :, sce - sce_start + 1] = sell_priority

        # (5) Final Cost.
        final_buy_price = sum(buy_bp, dims=1) / num_user
        final_sell_price = sum(sell_bp, dims=1) / num_user
        ####################################################################################################

        # (8) Battery capacity
        BatteryCap = Int(ceil(2 * maximum(solar)))
        # BatteryCap = 2
        
        ####################Load Scenario GRU Pred ###########################
        ## GRU
        # primal_pred_location = "D:/Jacky/Data Output/ADMM_P2P/Database/Test and Eval/2.1Plain PrioGO version chaos/LP_PrioGO_test_20_OldSame/predictions/primal_pred.npy"
        # primal_pred = npzread(primal_pred_location)
        # Poutaux_optimal = primal_pred[sce,:,:]
        # dual_pred_location = "D:/Jacky/Data Output/ADMM_P2P/Database/Test and Eval/2.1Plain PrioGO version chaos/LP_PrioGO_test_20_OldSame/predictions/dual_pred.npy"
        # dual_pred = npzread(dual_pred_location)
        # λ_optimal = dual_pred[sce,:,:]
        ########################################################################

        ub_CES = BatteryCap * ones(hour, num_user) #upper bound of CES capacity for each prosumers
        lb_CES = zeros(hour, num_user)
        ub_CESc = (BatteryCap / 3) * ones(hour, num_user) #charging bound for CES for each prosumer (0.5c)
        lb_CESc = zeros(hour, num_user)
        ub_CESd = (BatteryCap / 3) * ones(hour, num_user) #discharging bound for CES for each prosumer (0.5c)
        lb_CESd = zeros(hour, num_user)
        beta_tnb = 1 #priority index for trading in local market
        P_CES0 = (BatteryCap / 2) * ones(num_user)
        P2PTrade = [16 38]
        efficiency_CES = 0.9

        # Grid CES
        ces_size = [7.425284391]
        ub_CEScd_grid = (BatteryCap / 3) * num_user * ones(hour, num_ces)
        lb_CEScd_grid = zeros(hour, num_ces)
        ub_CES_grid = ones(hour) .* ces_size
        Pg_CES0 = ones(hour) .* ces_size .* 0.5

        # save to dictionary for prosumer model
        Param_Prosumer = Dict()
        Param_Prosumer[:ub_CES] = ub_CES
        Param_Prosumer[:lb_CES] = lb_CES
        Param_Prosumer[:ub_CESc] = ub_CESc
        Param_Prosumer[:lb_CESc] = lb_CESc
        Param_Prosumer[:ub_CESd] = ub_CESd
        Param_Prosumer[:lb_CESd] = lb_CESd
        Param_Prosumer[:hour] = hour
        Param_Prosumer[:beta_tnb] = beta_tnb
        Param_Prosumer[:CES0] = P_CES0
        Param_Prosumer[:P2PTrade] = P2PTrade
        Param_Prosumer[:efficiency_CES] = efficiency_CES
        Param_Prosumer[:buy_priority] = buy_priority
        Param_Prosumer[:sell_priority] = sell_priority
        Param_Prosumer[:load_demamd] = net_load'
        # Param_Prosumer[:bin_CES] = bin_CES
        Param_Prosumer[:bin_CES] = 0
        # CSV.write("D:/Jacky/Julia-vscode/ADMM_P2P_Data/33bus/Param_Prosumer.csv", Param_Prosumer)

        # save to dictionary for grid operator model
        Param_Grid = Dict()
        Param_Grid[:hour]           = hour 
        Param_Grid[:num_user]       = num_user
        Param_Grid[:ptdf]           = ptdf
        Param_Grid[:num_bus]        = nb_bus
        Param_Grid[:num_branch]     = nb_branch
        Param_Grid[:branch_limit]   = BranchLimit
        Param_Grid[:ub_CES]         = ub_CES_grid
        Param_Grid[:lb_CES]         = lb_CEScd_grid
        Param_Grid[:ub_CESc]        = ub_CEScd_grid
        Param_Grid[:lb_CESc]        = lb_CEScd_grid
        Param_Grid[:ub_CESd]        = ub_CEScd_grid
        Param_Grid[:lb_CESd]        = lb_CEScd_grid
        Param_Grid[:buy_priority]   = buy_priority
        Param_Grid[:sell_priority]  = sell_priority
        Param_Grid[:efficiency_CES] = efficiency_CES
        Param_Grid[:load_demamd]    = net_load'
        Param_Grid[:loc_prosumer]   = loc_prosumer
        Param_Grid[:P2PTrade]       = P2PTrade
        Param_Grid[:A_matrix]       = A_matrix
        Param_Grid[:A_trans]        = transpose(A_matrix)
        Param_Grid[:a_0]            = a_0
        Param_Grid[:D_r]            = D_r
        Param_Grid[:D_x]            = D_x
        Param_Grid[:num_ces]        = num_ces
        Param_Grid[:CES_loc_matrix] = CES_loc_matrix
        Param_Grid[:CES0]           = Pg_CES0
        # CSV.write("D:/Jacky/Julia-vscode/ADMM_P2P/Output/New/OneSce/Param_Grid.csv", Param_Grid)

        # parameters inititalize
        num_dec = 4
        rho_u = 0.6 #step size
        max_iteration = 5000
        λ = 0 * ones(num_dec * hour, num_user, max_iteration) # λ = [] dual value
        Pout = 0 * ones(num_dec * hour, num_user) # Pout = [] primal value
        Pout_all = 0 * ones(num_dec * hour, num_user, max_iteration) #storing all Pout
        Pout_aux_all = 0 * ones(num_dec * hour, num_user, max_iteration) #storing all Pout_aux
        P_decision_all = 0 * ones(8 * hour, num_user, max_iteration) #storing all P_decision
        Pout_aux = 0 * ones(num_dec * hour, num_user)
        ui_all = zeros(20, hour, num_user)
        Prosumer_decision = zeros(8 * hour, num_user)
        Grid_decision = zeros(2 * hour, num_user)
        subproblem_times = Vector{Vector{Float64}}() 

        # relaxation parameter
        alpha_relax = 1.5
        # Proximal term for ML anchor
        mu = rho_u
        decay = 0.95
        Param_Prosumer[:mu] = mu
        # Param_Prosumer[:prediction] = Poutaux_optimal
        Param_Prosumer[:pred_inj] = false
        Param_Prosumer[:num_dec] = num_dec
        Param_Grid[:mu] = mu
        # Param_Grid[:prediction] = Poutaux_optimal
        Param_Grid[:pred_inj] = false
        Param_Grid[:num_dec] = num_dec

        iteration_num = 2
        AI_inject_iter = 13
        total_cost = []
        obj_g = []
        converg_threshold_primal = 1e-3
        converg_threshold_dual = 1e-3
        rhov = []
        ctp = []
        ctd = []

        converg_num = []
        primal_error = []
        dual_error = []
        primal_residual = [1]
        dual_residual = []
        obj_all = []
        obj_p = []

        num_user_a = Int(sum(loc_prosumer))
        num_user_in = []

        # Find the prosumer involved in system
        for i in 1:nb_bus
            if length(findall(loc_prosumer[:,i] .== 1)) >0
                append!(num_user_in,vec(findall(loc_prosumer[:,i] .== 1))) 
                # println(vec(findall(loc_prosumer[:, i] .== 1)))
            end
        end 

        ############## Loop for ADMM algorithm ################
        while (primal_residual[end] > converg_threshold_primal ||
            dual_residual[end] > converg_threshold_dual) && iteration_num < max_iteration
            global Pout, Pout_aux, iteration_num, rho_u, Prosumer_decision, Grid_decision, ui_all

            if primal_residual[end] == 1
                primal_residual = []
            end
            if iteration_num == AI_inject_iter
                # λ[:,:,iteration_num-1] = λ_optimal
                # Pout_aux = Poutaux_optimal
                # Pout_aux_all[:, :, iteration_num-1] = Pout_aux

                # Param_Prosumer[:pred_inj] = true
                # Param_Grid[:pred_inj] = true
            end

            times_this_iter = zeros(num_user)
            # @time for k in 1:num_user  #calculate 15 prosumer problem in parallel
            # @time Threads.@threads for k in 1:num_user_a    #uncomment for parallel computing of Julia operation
            @time Threads.@threads for k in num_user_in    #uncomment for parallel computing of Julia operation
                start_time = time()
                # obj_Prosumer, P_decision_Prosumer, Pout_Prosumer, ui_prosumer = Subproblem_Prosumer(Param_Prosumer, Pout_aux, k, λ, iteration_num - 1) #prosumer problem takes in new Pout_aux and lambda
                obj_Prosumer, P_decision_Prosumer, Pout_Prosumer = Subproblem_Prosumer(Param_Prosumer, Pout_aux, k, λ, iteration_num - 1) #prosumer problem takes in new Pout_aux and lambda
                times_this_iter[k] = time() - start_time

                Pout[:, k] = Pout_Prosumer
                Prosumer_decision[:, k] = P_decision_Prosumer
                # ui_all[4:end, :, k] = ui_prosumer
            end
            
            push!(subproblem_times, times_this_iter)

            # ---> ADD OVER-RELAXATION HERE <---
            # alpha_relax is defined earlier as 1.5
            # Pout = alpha_relax .* Pout .+ (1 - alpha_relax) .* Pout_aux

            Pout_all[:, :, iteration_num] = Pout
            P_decision_all[:, :, iteration_num] = Prosumer_decision

            if iteration_num == AI_inject_iter #take in AI PRIMAL pred 
                # λ[:,:,iteration_num-1] = λ_optimal
                # Pout = Poutaux_optimal
                # Pout_all[:, :, iteration_num] = Pout
            end

            # obj_Grid, Pout_Grid, P_decision_Grid, Grid_CES = Subproblem_Grid_Operator(Param_Grid, Pout, λ, iteration_num - 1) #gather Pout and send to grid operator master problem
            # obj_Grid, Pout_Grid, P_decision_Grid, ui_grid = Subproblem_Grid_Operator(Param_Grid, Pout, λ, iteration_num - 1) #gather Pout and send to grid operator master problem
            obj_Grid, Pout_Grid, P_decision_Grid = Subproblem_Grid_Operator(Param_Grid, Pout, λ, iteration_num - 1) #gather Pout and send to grid operator master problem
            Pout_aux = Pout_Grid
            Grid_decision = P_decision_Grid
            Pout_aux_all[:, :, iteration_num] = Pout_aux
            # Grid_CES_all[:, :, iteration_num] = Grid_CES
            # ui_all[1:3, :, :] = ui_grid

            λ[:, :, iteration_num] = λ[:, :, iteration_num-1] + rho_u * (Pout_aux - Pout) # update λ

            append!(obj_g, obj_Grid)
            append!(primal_error, sum(abs.(Pout - Pout_aux)))
            append!(dual_error, sum(abs.(rho_u * (λ[:, :, iteration_num] - λ[:, :, iteration_num-1]))))            
            append!(primal_residual, sqrt(sum((Pout - Pout_aux) .^ 2)))
            append!(dual_residual, sqrt(sum((rho_u * (λ[:, :, iteration_num] - λ[:, :, iteration_num-1])) .^ 2)))            
            append!(obj_all, obj(Pout_aux, Prosumer_decision, buy_priority, sell_priority, beta_tnb))
            append!(obj_p, obj(Pout, Prosumer_decision, buy_priority, sell_priority, beta_tnb))

            println("----------------------------------------------------------------")
            println(" Primal Error is ", primal_residual[end])
            println(" Dual Error is ", dual_residual[end])
            println(" Number of iterations is ", iteration_num)
            println(" Scenario number: ", sce)
            println("----------------------------------------------------------------")
            append!(ctp, converg_threshold_primal)
            append!(ctd, converg_threshold_dual)

            iteration_num = iteration_num + 1
            if iteration_num > AI_inject_iter
                # devay proximal term
                mu = mu * decay
                Param_Prosumer[:mu] = mu
                Param_Grid[:mu] = mu
            end

            if iteration_num > max_iteration
                break
            end
        end
        push!(converg_num, iteration_num - 1)

    end # for execution_times
    println("#######################################")
    println(" Finished sce: ", sce)
    println(" Primal Error is ", primal_residual[end])
    println(" Dual Error is ", dual_residual[end])
    println(" Number of iterations is ", iteration_num - 1)
    println(" Time taken: ", elapsed_time)
    println("#######################################")

    # draw the results
    p = plot(primal_residual, 
                label="Primal Residual", 
                xlabel="Number of iterations", 
                ylabel="Residual", 
                yscale=:log10, 
                title="ADMM Convergence\nScenario $(sce), Iterations: $(iteration_num-1), Time: $(round(elapsed_time, digits=2)) seconds", 
                titlefontsize=8,
                size=(600, 400))
    plot!(p, dual_residual, label="Dual Residual")
    display(p)
    
    push!(execution_times, elapsed_time)
    # train_primal_error[sce - sce_start + 1, iteration_num-1] = primal_error[end]
    # train_primal_residual[sce - sce_start + 1, iteration_num-1] = primal_residual[end]
    # train_dual_error[sce - sce_start + 1, iteration_num-1] = dual_error[end]
    # train_dual_residual[sce - sce_start + 1, iteration_num-1] = dual_residual[end]
    # train_obj[sce - sce_start + 1, iteration_num-1] = obj_all[end]

    prosumer_cost, TNBearn = ProfitCal(Prosumer_decision, buy_priority, sell_priority, total_excess, net_load, buy_bp, sell_bp, tnb_cost, power_consumption, SolarScaler, BatteryCap, P2PTrade)
    # prosumer_cost_all[:,sce] = prosumer_cost
    # TNBearning_all[:,sce] = TNBearn
    # ProfitSave(prosumer_cost,TNBearn)

    # savefig(peplot, "D:/Jacky/Julia-vscode/ADMM_P2P/Output/New/OneSce/Fig/primal error.svg")
    # savefig(deplot, "D:/Jacky/Julia-vscode/ADMM_P2P/Output/New/OneSce/Fig/dual error.svg")
    # savefig(prplot, "D:/Jacky/Julia-vscode/ADMM_P2P/Output/New/OneSce/Fig/primal residual.svg")
    # savefig(drplot, "D:/Jacky/Julia-vscode/ADMM_P2P/Output/New/OneSce/Fig/dual residual.svg")
    # CSV.write("D:/Jacky/Julia-vscode/ADMM_P2P/Output/New/OneSce/subproblem_times.csv", DataFrame(hcat(subproblem_times...), :auto), writeheader=false)
    
    if iteration_num == max_iteration
        push!(optimal_num, 0)
        push!(infeasible_sce, sce)
        subset_dualdata = λ[:, :, [100:124; iteration_num-25:iteration_num-1]]
        subset_primaldata = Pout_aux_all[:, :, [100:124; iteration_num-25:iteration_num-1]]
        subset_P_decisiondata = P_decision_all[:, :, [100:124; iteration_num-25:iteration_num-1]]

        train_dual[sce - sce_start + 1, :, :, :] = zeros(4 * 48, num_user, 51)
        train_primal[sce - sce_start + 1, :, :, :] = zeros(4 * 48, num_user, 51)
        train_P_decision[sce - sce_start + 1, :, :, :] = zeros(8 * 48, num_user, 51)

        infeasible = 1
    else
        # store converged num, dual and primal [1:K_pred and optimal value] for the scenario
        push!(optimal_num, iteration_num - 1)
        # subset_dualdata = λ[:, :, [100:124; iteration_num-25:iteration_num-1]]
        # subset_primaldata = Pout_aux_all[:, :, [100:124; iteration_num-25:iteration_num-1]]
        # subset_P_decisiondata = P_decision_all[:, :, [100:124; iteration_num-25:iteration_num-1]]

        # train_dual[sce, :, :, :] = subset_dualdata
        # train_primal[sce, :, :, :] = subset_primaldata
        # train_P_decision[sce, :, :, :] = subset_P_decisiondata
        train_dual[sce - sce_start + 1, :, :, :] = zeros(4 * 48, num_user, 51)
        train_primal[sce - sce_start + 1, :, :, :] = zeros(4 * 48, num_user, 51)
        train_P_decision[sce - sce_start + 1, :, :, :] = zeros(8 * 48, num_user, 51)
    end

    ##################################################################################################################
    # Price calculation #
    ##################################################################################################################
    ResultPrint(Prosumer_decision, Grid_decision, buy_priority, sell_priority, total_excess, net_load, buy_bp, sell_bp, tnb_cost, power_consumption, SolarScaler, BatteryCap, P2PTrade, Param_Grid)
    # plot_all(Prosumer_decision, Grid_decision, buy_bp, sell_bp, bus_sys, sce)
    
    ##################################################################################################################
    # Data Saving one scenario #
    ##################################################################################################################
    oneSave(Pout_aux, reshape(λ[:,:,iteration_num-1],size(λ)[1:2]), Prosumer_decision, Grid_decision, execution_times, 
    optimal_num, primal_error, dual_error, primal_residual, dual_residual, obj_all, buy_priority, sell_priority, 
    Pout_aux_all[:,:,1:iteration_num-1], λ[:,:,1:iteration_num-1], Pout_all[:,:,1:iteration_num-1], net_load', loc_prosumer)
end

msg = "ADMM_CES_2 completed."
send_notification(msg)