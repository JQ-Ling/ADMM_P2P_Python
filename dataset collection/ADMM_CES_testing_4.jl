using JuMP, CSV, DataFrames, Gurobi, Random, Plots, Printf, Dates, NPZ, JSON, HTTP

config_name = "config_testing_4"
config_path = "D:/Jacky/Python/ADMM_P2P_Python/dataset collection/$(config_name).json"
config = JSON.parsefile(config_path)
path = config["project_name"]
testdataset = config["testdataset"]
iter_save = config["iter_save"]

file_dir = "D:/Jacky/Data Output/ADMM_P2P/New"
dir_path = "$(file_dir)/$(path)"

include(config["ADMM_ver"])
include("D:/Jacky/Python/ADMM_P2P_Python/utils/Price_fcn.jl")
include("D:/Jacky/Python/ADMM_P2P_Python/utils/Data Saving.jl") 

# Step # 1 : Obtain Data and setting for Parameter
# (1) -> Power Consumption
# (2) -> Solar Generation.
# (3) -> Net Load
# (4) -> Bidding Price and Priority
# (5) -> Final Price
# (6) -> PTDF

# (1) Power Consumption.
# PowerConsumption[Prosumer][Hour]
char_data_location_1 = "D:/Jacky/Julia-vscode/ADMM_P2P/Power Consumption_33_bus.csv"
power_consumption_data = (CSV.File(char_data_location_1) |> DataFrame)
LoadScaler = 1
power_consumption = Matrix(power_consumption_data) ./2 .* LoadScaler

nb_prosumer = size(power_consumption_data, 2)  # number of prosumers
nb_hour = size(power_consumption_data, 1)  # time
hour = nb_hour
num_user = nb_prosumer
# nb_hour = 24  # time

println("No. Prosumer = ", nb_prosumer)
println("No. Time Step = ", nb_hour)

# (2) Solar
# Solar[Hour]
char_data_location_2 = "D:/Jacky/Julia-vscode/ADMM_P2P/Solar_interpolated_6000.csv"
net_load_data = CSV.File(char_data_location_2, header=true) |> DataFrame

SolarScaler = 1
interpolated_solar_scenarios = Matrix(net_load_data) .* SolarScaler

# (6) PTDF
ptdf_file_location = "D:/Jacky/Julia-vscode/ADMM_P2P/radial33bus_PTDF.csv"
ptdf_data = CSV.File(ptdf_file_location, header=false) |> DataFrame

nb_bus = size(ptdf_data, 2)
nb_branch = size(ptdf_data, 1)
ptdf = Matrix(ptdf_data)

println("nbBus: ", nb_bus)
println("nbBranch: ", nb_branch)

# (7) Branch limit
BranchLimit_file_location = "D:/Jacky/Julia-vscode/ADMM_P2P/33_bus_limit_data.csv"
BranchLimit_data = CSV.File(BranchLimit_file_location, header=true) |> DataFrame

BranchLimit = BranchLimit_data[!,1] .* 1000

# Save to CSV (unchange throughout all scenarios)
# loc_CES = zeros(1, nb_bus)
# loc_CES[2] = 1 
# # loc_CES[[18 22 25 33]] .= 1 # CES of Prosumer and TNB (same bus)
# # loc_CES[[17 21 24 32]] .= 2 # CES of TNB
# # CSV.write("D:/Jacky/Julia-vscode/ADMM_P2P/Output/New/ADMM_P2P_Data/CES_location.csv", DataFrame(loc_CES, :auto))

########################################################################################################

# set your starting scenario and ending scenario number to generate
config["last_processed_index"] == 0 ? sce_start = config["sce_start"] : sce_start = config["last_processed_index"] + 1
sce_end = config["sce_end"]
tot_sce = sce_end - config["sce_start"] + 1

num_dec = config["number of decisions"]
execution_times = []
optimal_num = []
infeasible_sce = []
infeasible = 0
train_dual = zeros(5, num_dec * nb_hour, num_user, config["iter_save"]+1)
train_primal = zeros(5, num_dec * nb_hour, num_user, config["iter_save"]+1)
train_P_decision = zeros(5, 8 * nb_hour, num_user, config["iter_save"]+1)
loc_pros_solar_all = zeros(5, num_user)
loc_prosumer_all = zeros(num_user, nb_bus, 5)
train_primal_error = fill(NaN, 5, 5000) # scenario by max_iteration
train_primal_residual = fill(NaN, 5, 5000)
train_dual_error = fill(NaN, 5, 5000)
train_dual_residual = fill(NaN, 5, 5000)
train_obj = fill(NaN, 5, 5000)
buy_priority_all = zeros(nb_prosumer, nb_hour, 5)
sell_priority_all = zeros(nb_prosumer, nb_hour, 5)
prosumer_cost_all = zeros(224,tot_sce)
TNBearning_all = zeros(5,tot_sce)

@time for sce in sce_start:sce_end
    # @time for no_run in 1:5
    elapsed_time = @elapsed begin

        global Param_Prosumer, Param_Grid, Pout_all, λ, Pout, Pout_aux, primal_error, dual_error,
        Prosumer_decision, Grid_decision, iteration_num, rho_u, net_load, primal_residual,
        dual_residual, rhov, loc_prosumer, loc_CES, tc2, tc3, count_tc2, count_tc3, obj_all, P_decision_all, Pout_aux_all,
        infeasible_sce, infeasible, obj_g, obj_p, Grid_CES_all, ctp, ctd, subproblem_times

        solar = interpolated_solar_scenarios[sce,:]

        # (3) Net Load
        # NetLoad[Prosumer][Hour]
        # Param (locations)
        max_pros = nb_bus/3 # max prosumer in one bus for test case 3

        pros_solar = Int(ceil(nb_prosumer / 2))

        # Normal
        # net_load = power_consumption' .- solar' #netload < 0 -> surplus energy
        net_load = copy(power_consumption')
        net_load[pros_solar:end, :] .-= 1.5 * solar'    

        # for AI testing purpose
        if sce % 5 == 1
            fs = sce
            ls = sce + 4
        elseif sce%5 ==0
            fs = sce - 4
            ls = sce
        else
            fs = sce - sce % 5 + 1
            ls = sce - sce % 5 + 5
        end

        loc_sce = sce % 5
        if loc_sce == 0
            loc_sce = 5
        end
        
        if config["is_csv"]
            ## CSV dataset ##################################################
            loc_p_file = "$(testdataset)/location/location_prosumer_$(fs)to$(ls)sce.csv"
            bp_file = "$(testdataset)/DecisionVariable/buy_priority_$(fs)to$(ls)sce.csv"
            sp_file = "$(testdataset)/DecisionVariable/sell_priority_$(fs)to$(ls)sce.csv"

            loc_p = Matrix(CSV.File(loc_p_file, header=true) |> DataFrame)
            bp = Matrix(CSV.File(bp_file, header=true) |> DataFrame)
            sp = Matrix(CSV.File(sp_file, header=true) |> DataFrame)

            loc_prosumer_5sce = reshape(loc_p, (num_user, nb_bus, 5))
            bp_5sce = reshape(bp, (num_user, nb_hour, 5))
            sp_5sce = reshape(sp, (num_user, nb_hour, 5))
            
            loc_prosumer = loc_prosumer_5sce[:,:,loc_sce]
            ##################################################
        else
            ## NPZ dataset ##################################################
            loc_p_file = "$(testdataset)/location/location_prosumer_$(sce).csv"
            bp_file = "$(testdataset)/DecisionVariable/buy_priority.npz"
            sp_file = "$(testdataset)/DecisionVariable/sell_priority.npz"

            loc_prosumer = Matrix(CSV.File(loc_p_file, header=true) |> DataFrame)
            bp_5sce = reshape(npzread(bp_file)[(Int(round(fs/5))*num_user*nb_hour+1):Int(round(fs/5+1))*num_user*nb_hour,:], (num_user, nb_hour, 5))
            sp_5sce = reshape(npzread(sp_file)[(Int(round(fs/5))*num_user*nb_hour+1):Int(round(fs/5+1))*num_user*nb_hour,:], (num_user, nb_hour, 5))
            ##################################################
        end
        
        buy_priority = bp_5sce[:,:,loc_sce]
        sell_priority = sp_5sce[:,:,loc_sce]
        loc_prosumer_all[:, :, loc_sce] = loc_prosumer
        # num_user_set = [k for k in 1:nb_prosumer if sum(loc_prosumer[k, :]) == 1]
        loc_pros_solar = zeros(nb_prosumer)
        loc_pros_solar = [1 * (sum(loc_prosumer[k, :]) == 1 && k >= pros_solar) for k in 1:nb_prosumer]
        loc_pros_solar_all[loc_sce, :] = loc_pros_solar

        # (4) Bidding Price and Bidding Priority
        # (4.1) TNB Cost
        tnb_cost = [0.57, 0.15]

        # (2.2) Bidding Cost
        total_excess = zeros(nb_hour)
        total_deficiency = zeros(nb_hour)

        for i in 1:nb_hour
            total_excess[i] = sum(net_load[j, i] < 0 ? -net_load[j, i] : 0 for j in 1:nb_prosumer)
            total_deficiency[i] = sum(net_load[j, i] > 0 ? net_load[j, i] : 0 for j in 1:nb_prosumer)
        end

        # BuyPriority[Prosumer][Time Step]   SellPriority[Prosumer][Time Step]
        bpp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/buy_price_33.csv"
        spp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/sell_price_33.csv"
        # bp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/buy_priority_33.csv"
        # sp_file = "D:/Jacky/Julia-vscode/ADMM_P2P/sell_priority_33.csv"

        buy_bp = Matrix(CSV.File(bpp_file, header=false) |> DataFrame)
        sell_bp = Matrix(CSV.File(spp_file, header=false) |> DataFrame)
        # buy_priority = Matrix(CSV.File(bp_file, header=false) |> DataFrame)
        # sell_priority = Matrix(CSV.File(sp_file, header=false) |> DataFrame)

        buy_priority_all[:, :, loc_sce] = buy_priority
        sell_priority_all[:, :, loc_sce] = sell_priority

        # (5) Final Cost.
        # final_buy_price = sum(buy_bp, dims=1) / nb_prosumer
        # final_sell_price = sum(sell_bp, dims=1) / nb_prosumer

        # (8) Battery capacity
        BatteryCap = Int(ceil(2 * maximum(solar)))
        # BatteryCap = 2

        #################### Load Scenario AI Pred ###########################
        ## GRU
        if config["injection"]
            primal_pred_location = config["primal_pred_loc"]
            primal_pred = npzread(primal_pred_location)
            Poutaux_optimal = primal_pred[sce,:,:]
        end
        
        if config["injection"]
            dual_pred_location = config["dual_pred_loc"]
            dual_pred = npzread(dual_pred_location)
            λ_optimal = dual_pred[sce,:,:]
        end

        # Poutaux_optimal = [Poutaux_optimal[97:end,:]; Poutaux_optimal[1:96,:]]

        # ## Transformer
        # primal_pred_location = "C:/Users/PC/Desktop/JKFYP/p2p_test12_data/large_wd5e-4/primal_pred.npy"
        # primal_pred = npzread(primal_pred_location)
        # Poutaux_optimal = primal_pred[sce,:,:]'
        # # Poutaux_optimal = primal_pred[sce-5000,:,:]'
        # dual_pred_location = "C:/Users/PC/Desktop/JKFYP/p2p_test12_data/large_wd5e-4/dual_pred.npy"
        # dual_pred = npzread(dual_pred_location)
        # λ_optimal = dual_pred[sce,:,:]'
        # # λ_optimal = dual_pred[sce-5000,:,:]'

        # ## load own optimal solution
        # # CSV format
        # primal_file = "D:/Jacky/Data Output/ADMM_P2P/Database/TC1_MILP_olderr_32_new/33bus/primal_$(fs)to$(ls)sce.csv"
        # dual_file = "D:/Jacky/Data Output/ADMM_P2P/Database/TC1_MILP_olderr_32_new/33bus/dual_$(fs)to$(ls)sce.csv"
        # primal_gt = Matrix(CSV.File(primal_file, header=true) |> DataFrame)
        # Poutaux_optimal = reshape(primal_gt, (5, 4*48, num_user, 51))[loc_sce, :, :, end]
        # dual_gt = Matrix(CSV.File(dual_file, header=true) |> DataFrame)
        # λ_optimal = reshape(dual_gt, (5, 4*48, num_user, 51))[loc_sce, :, :, end]

        # NPZ format 
        # primal_opt_loc = "$(testdataset)/primalGRU.npy"
        # Poutaux_optimal = npzread(primal_opt_loc)[sce,:,:,end]
        # dual_opt_loc = "$(testdataset)/dualGRU.npy"
        # λ_optimal = npzread(dual_opt_loc)[sce,:,:,end]
        # primal_opt_loc = "D:/Jacky/Julia-vscode/ADMM_P2P/AI_pred/Prediction evaluation/adjusted_primal.npz"
        # Poutaux_optimal = npzread(primal_opt_loc)

        ## Desired RMSE Analysis
        # primal_opt_loc = "D:/Jacky/Julia-vscode/ADMM_P2P/AI_pred/Prediction evaluation/adjusted_primal.npz"
        # Poutaux_optimal = npzread(primal_opt_loc)

        ## P2P trade error Analysis
        # primal_opt_loc = "$(testdataset)/primalGRU.npy"
        # mid_primal = npzread(primal_opt_loc)[sce,:,:,300]
        # Poutaux_optimal[3*hour+1:4*hour, 1:15] = mid_primal[3*hour+1:4*hour, 1:15]
        # Poutaux_optimal[2*hour+1:3*hour, 16:end] = mid_primal[2*hour+1:3*hour, 16:end]

        # #### Post-Processing ####
        # P_load = net_load'
        # B_load = zeros(size(P_load))
        # B_load[findall(P_load .> 0)] .= 1 # 1 = TNL, 0 = TSE
    
        # obj_pred, Poutaux_optimal, _ = Subproblem_Grid_Operator(Param_Grid, Poutaux_optimal, λ_optimal, 1)
        # Poutaux_optimal[193:240,:] = Poutaux_optimal[193:240,:] .* B_load
        # Poutaux_optimal[241:end,:] = Poutaux_optimal[241:end,:] .* (1 .- B_load)
        # Poutaux_optimal[findall(x->x<1e-4, Poutaux_optimal)] .= 0
        # ########################################################################

        ub_CES = BatteryCap * ones(hour, nb_prosumer) #upper bound of CES capacity for each prosumers
        lb_CES = zeros(hour, nb_prosumer)
        ub_CESc = (BatteryCap / 3) * ones(hour, nb_prosumer) #charging bound for CES for each prosumer
        lb_CESc = zeros(hour, nb_prosumer)
        ub_CESd = (BatteryCap / 3) * ones(hour, nb_prosumer) #discharging bound for CES for each prosumer
        lb_CESd = zeros(hour, nb_prosumer)
        beta_tnb = 1 #priority index for trading in local market
        P_CES0 = (BatteryCap / 2) * ones(nb_prosumer)
        P2PTrade = [16 38]
        efficiency_CES = 0.9
        
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

        # save to dictionary for grid operator model
        Param_Grid = Dict()
        Param_Grid[:hour] = hour 
        Param_Grid[:num_user] = num_user
        Param_Grid[:ptdf] = ptdf
        Param_Grid[:num_bus] = nb_bus
        Param_Grid[:num_branch] = nb_branch
        Param_Grid[:branch_limit] = BranchLimit
        Param_Grid[:ub_CES] = ub_CES
        Param_Grid[:lb_CES] = lb_CES
        Param_Grid[:ub_CESc] = ub_CESc
        Param_Grid[:lb_CESc] = lb_CESc
        Param_Grid[:ub_CESd] = ub_CESd
        Param_Grid[:lb_CESd] = lb_CESd
        Param_Grid[:buy_priority] = buy_priority
        Param_Grid[:sell_priority] = sell_priority
        Param_Grid[:efficiency_CES] = efficiency_CES
        Param_Grid[:load_demamd] = net_load'
        Param_Grid[:loc_prosumer] = loc_prosumer
        Param_Grid[:P2PTrade] = P2PTrade

        # parameters inititalize
        rho_u = 0.6 #step size
        max_iteration = 5000
        λ = 0 * ones(num_dec * hour, num_user, max_iteration) # λ = [] dual value
        Pout = 0 * ones(num_dec * hour, num_user) # Pout = [] primal value
        Pout_all = 0 * ones(num_dec * hour, num_user, max_iteration) #storing all Pout
        Pout_aux_all = 0 * ones(num_dec * hour, num_user, max_iteration) #storing all Pout_aux
        Pout_aux = 0 * ones(num_dec * hour, num_user)

        P_decision_all = 0 * ones(8 * hour, num_user, max_iteration) #storing all P_decision
        Prosumer_decision = zeros(8 * hour, num_user)
        Grid_decision = zeros(2 * hour, num_user)

        # relaxation parameter
        alpha_relax = config["relaxation parameter"]
        # Proximal term for ML anchor
        mu = rho_u
        decay = 0.95
        Param_Prosumer[:mu] = mu
        Param_Prosumer[:prediction] = Poutaux_optimal
        Param_Prosumer[:pred_inj] = false
        Param_Grid[:mu] = mu
        Param_Grid[:prediction] = Poutaux_optimal
        Param_Grid[:pred_inj] = false
        
        iteration_num = 2
        AI_inject_iter = config["injection_iter"]
        obj_g = []
        converg_threshold_primal = config["threshold"]
        converg_threshold_dual = config["threshold"]
        rhov = []
        ctp = []
        ctd = []
        subproblem_times = Vector{Vector{Float64}}() 

        # warm-start
        # λ[:,:,iteration_num-1] = λ_optimal
        # Pout = Poutaux_optimal
        # Pout_aux = Poutaux_optimal

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
            global Pout, Pout_aux, iteration_num, rho_u, Prosumer_decision, Grid_decision, pr_ba, iter_ba, dr_ba
            
            if primal_residual[end] == 1
                primal_residual =[]
            end
            if iteration_num == AI_inject_iter  #take in AI Pout_aux pred on 11th loop
                # pr_ba = [primal_residual[end]]
                # dr_ba = [dual_residual[end]]
                # iter_ba = [length(primal_residual)]
                if config["injection_pros"] && config["injection"]
                    λ[:,:,iteration_num-1] = λ_optimal
                    Pout_aux = Poutaux_optimal
                    Pout_aux_all[:, :, iteration_num-1] = Pout_aux

                    Param_Prosumer[:pred_inj] = true
                    Param_Grid[:pred_inj] = true
                end
            end
            
            times_this_iter = zeros(num_user)
            # @time for k in 1:num_user  #calculate 15 prosumer problem in parallel
            # @time Threads.@threads for k in 1:num_user_a    #uncomment for parallel computing of Julia operation
            @time Threads.@threads for k in num_user_in    #uncomment if prosumer can randomly involved in system
                start_time = time()
                # if iteration_num >= AI_inject_iter
                #     obj_Prosumer, P_decision_Prosumer, Pout_Prosumer = Subproblem_Prosumer_prediction(Param_Prosumer, Pout_aux, k, λ, iteration_num - 1) #prosumer problem takes in new Pout_aux and lambda
                # else
                #     obj_Prosumer, P_decision_Prosumer, Pout_Prosumer = Subproblem_Prosumer(Param_Prosumer, Pout_aux, k, λ, iteration_num - 1) #prosumer problem takes in new Pout_aux and lambda
                # end
                obj_Prosumer, P_decision_Prosumer, Pout_Prosumer = Subproblem_Prosumer(Param_Prosumer, Pout_aux, k, λ, iteration_num - 1) #prosumer problem takes in new Pout_aux and lambda
                times_this_iter[k] = time() - start_time

                Pout[:, k] = Pout_Prosumer
                Prosumer_decision[:, k] = P_decision_Prosumer
            end
            push!(subproblem_times, times_this_iter)

            if config["over-relaxation"]
                Pout = alpha_relax .* Pout .+ (1 - alpha_relax) .* Pout_aux # over-relaxation step
            end

            Pout_all[:, :, iteration_num] = Pout
            P_decision_all[:, :, iteration_num] = Prosumer_decision

            if iteration_num == AI_inject_iter && !config["injection_pros"] && config["injection"]
                λ_temp = λ[:,:,iteration_num-1]
                λ[:,:,iteration_num-1] = λ_optimal
                Pout = Poutaux_optimal
                Pout_all[:, :, iteration_num] = Pout
            end
            
            obj_Grid, Pout_Grid, P_decision_Grid = Subproblem_Grid_Operator(Param_Grid, Pout, λ, iteration_num - 1) #gather Pout and send to grid operator master problem
            Pout_aux = Pout_Grid
            Grid_decision = P_decision_Grid
            Pout_aux_all[:, :, iteration_num] = Pout_aux
            
            # update λ
            λ[:, :, iteration_num] = λ[:, :, iteration_num-1] + rho_u * (Pout_aux - Pout) 
            
            # record objective and residual
            append!(obj_g, obj_Grid)
            append!(primal_error, sum(abs.(Pout - Pout_aux)))
            append!(dual_error, sum(abs.(rho_u * (λ[:, :, iteration_num] - λ[:, :, iteration_num-1]))))
            append!(primal_residual, sqrt(sum((Pout - Pout_aux) .^ 2)))
            append!(dual_residual, sqrt(sum((rho_u * (λ[:, :, iteration_num] - λ[:, :, iteration_num-1])) .^ 2)))
            append!(obj_all, obj(Pout_aux, Prosumer_decision, buy_priority, sell_priority, beta_tnb))
            append!(obj_p, obj(Pout, Prosumer_decision, buy_priority, sell_priority, beta_tnb))

            train_primal_error[loc_sce, iteration_num-1] = primal_error[end]
            train_primal_residual[loc_sce, iteration_num-1] = primal_residual[end]
            train_dual_error[loc_sce, iteration_num-1] = dual_error[end]
            train_dual_residual[loc_sce, iteration_num-1] = dual_residual[end]
            train_obj[loc_sce, iteration_num-1] = obj_all[end]
            if iteration_num == AI_inject_iter # save after injection
                # append!(pr_ba, primal_residual[end])
                # append!(dr_ba, dual_residual[end])
                # append!(iter_ba, length(primal_residual))
            end

            println("----------------------------------------------------------------")
            println(" Primal Error is ", primal_error[end])
            println(" Dual Error is ", dual_error[end])
            println(" Number of iterations is ", iteration_num)
            print(" Scenario number: ", sce)
            config["injection"] ? println(" (AI Injection at iteration ", AI_inject_iter, ")") : println()
            println("----------------------------------------------------------------")
            append!(ctp, converg_threshold_primal)
            append!(ctd, converg_threshold_dual)

            if iteration_num >= AI_inject_iter && config["proximal decay"]
                # devay proximal term
                mu = mu * decay
                Param_Prosumer[:mu] = mu
                Param_Grid[:mu] = mu
            end
            iteration_num = iteration_num + 1
        end
        push!(converg_num, iteration_num-1)

        println("#######################################")
        println("Finished sce: ", sce)
        println("#######################################")

        

    end # for execution_times
    println("#######################################")
    println(" Finished sce: ", sce)
    println(" Primal Error is ", primal_residual[end])
    println(" Dual Error is ", dual_residual[end])
    println(" Number of iterations is ", iteration_num - 1)
    println(" Time taken: ", elapsed_time)
    println("#######################################")

    p = plot(primal_residual, 
            label="Primal Residual", 
            xlabel="Number of iterations", 
            ylabel="Residual", 
            yscale=:log10, 
            title="$(config["project_name"]) - Scenario $(sce), Iterations: $(iteration_num-1), Time: $(round(elapsed_time, digits=2)) seconds", 
            titlefontsize=8,
            size=(600, 400))
    plot!(p, dual_residual, label="Dual Residual")
    display(p)

    push!(execution_times, elapsed_time)
    prosumer_cost, TNBearn = ProfitCal(Prosumer_decision, buy_priority, sell_priority, total_excess, net_load, buy_bp, sell_bp, tnb_cost, power_consumption, SolarScaler, BatteryCap, P2PTrade)
    prosumer_cost_all[:,sce] = prosumer_cost
    TNBearning_all[:,sce] = TNBearn

    if iteration_num == max_iteration
        push!(optimal_num, 0)
        push!(infeasible_sce, sce)
        
        train_dual[(sce-1)%5 + 1, :, :, :] = zeros(size(train_dual)[2:end])
        train_primal[(sce-1)%5 + 1, :, :, :] = zeros(size(train_primal)[2:end])
        train_P_decision[(sce-1)%5 + 1, :, :, :] = zeros(size(train_P_decision)[2:end])

        infeasible = 1
    else
        # store converged num, dual and primal [1:K_pred and optimal value] for the scenario
        push!(optimal_num, iteration_num-1)
        subset_dualdata = λ[:, :, [3:iter_save+2; iteration_num-1]]
        subset_primaldata = Pout_aux_all[:, :, [3:iter_save+2; iteration_num-1]]
        subset_P_decisiondata = P_decision_all[:, :, [3:iter_save+2; iteration_num-1]]

        train_dual[loc_sce, :, :, :] = subset_dualdata
        train_primal[loc_sce, :, :,:] = subset_primaldata
        train_P_decision[loc_sce, :, :, :] = subset_P_decisiondata

    end

    # Save checkpoint every 5 scenarios (can adjust for more frequent saving if needed)
    if sce % 5 == 0
        if config["save_csv"]
            savetoCSV(1+(sce-5),sce, train_primal, train_dual, train_P_decision, loc_pros_solar_all, loc_prosumer_all, 
                execution_times, optimal_num, config["sce_start"], sce_end, infeasible, infeasible_sce, train_primal_error, train_primal_residual,
                train_dual_error, train_dual_residual, train_obj, buy_priority_all, sell_priority_all,prosumer_cost_all,TNBearning_all, dir_path, config, Param_Prosumer, Param_Grid)
        else
            savetoNPZ(1+(sce-5),sce, train_primal, train_dual, train_P_decision, loc_pros_solar_all, loc_prosumer_all, 
            execution_times, optimal_num, config["sce_start"], sce_end, infeasible, infeasible_sce, train_primal_error, train_primal_residual,
            train_dual_error, train_dual_residual, train_obj, buy_priority_all, sell_priority_all,prosumer_cost_all,TNBearning_all, dir_path, config, Param_Prosumer, Param_Grid)
        end
        infeasible = 0

        fill!(train_dual, 0)
        fill!(train_primal, 0)
        fill!(train_P_decision, 0)
        fill!(loc_pros_solar_all, 0)
        fill!(loc_prosumer_all, 0)
        fill!(train_primal_error, 0)
        fill!(train_primal_residual, 0)
        fill!(train_dual_error, 0)
        fill!(train_dual_residual, 0)
        fill!(train_obj, 0)
        fill!(buy_priority_all, 0)
        fill!(sell_priority_all, 0)
    end
    # oneSave(Pout_aux, reshape(λ[:,:,iteration_num-1],size(λ)[1:2]), Prosumer_decision, Grid_decision, execution_times, 
    # optimal_num, primal_error, dual_error, primal_residual, dual_residual, obj_all, buy_priority, sell_priority, 
    # Pout_aux_all[:,:,1:iteration_num-1], λ[:,:,1:iteration_num-1], Pout_all[:,:,1:iteration_num-1], net_load', loc_prosumer)
end


msg = "$(config["project_name"]) - Completed $(tot_sce) scenarios collection."
send_notification(msg)