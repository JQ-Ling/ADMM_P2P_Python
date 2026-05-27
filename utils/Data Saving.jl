using Glob, CSV, DataFrames, NPZ, Dates, JSON, HTTP, StatsBase

function obj(Pout_aux, P_decision, buy_bp, sell_bp, beta_tnb)
    P_c = Pout_aux[0*hour+1:1*hour, :]
    P_d = Pout_aux[1*hour+1:2*hour, :]
    P_buy = Pout_aux[2*hour+1:3*hour, :]
    P_sell = Pout_aux[3*hour+1:4*hour, :]
    Pg_buy = P_decision[0*hour+1:1*hour, :]
    Pg_sell = P_decision[1*hour+1:2*hour, :]

    f_1 = sum(P_buy .* buy_bp' + P_sell .* sell_bp')
    f_2 = sum(beta_tnb .* (Pg_buy + Pg_sell))
    f_3 = sum(0.005 .* (P_c + P_d))

    obj = f_1 + f_2 + f_3
    return obj
end

function savetoCSV(first, last, train_primal, train_dual, train_P_decision, loc_pros_solar_all, loc_prosumer_all,
    execution_times, optimal_num, sce_start, sce_end, infeasible, infeasible_sce, train_primal_error, train_primal_residual,
    train_dual_error, train_dual_residual, train_obj, buy_priority_all, sell_priority_all, pc, te, path, config, Param_Prosumer, Param_Grid,
    ledger_for_export=nothing)

    if isdir(path)
        println("Folder exists: ", path)
    else
        println("Folder does not exist, creating it.")
        mkpath(path) 
        mkpath(joinpath(path, "DecisionVariable"))
        mkpath(joinpath(path, "optimal_iter"))
        mkpath(joinpath(path, "location"))
        mkpath(joinpath(path, "infeasible_sce"))
        mkpath(joinpath(path, "Profit"))
    end

    ############# STORING OPTIMAL PRIMAL & DUAL to CSV ###############
    # for those dimension more than 2D, too large to save for all scenarios, 5 scenarios a csv file
    train_primal_set1 = train_primal
    train_dual_set1 = train_dual
    train_P_decision_set1 = train_P_decision
    loc_prosumer_set1 = loc_prosumer_all
    buy_priority_set1 = buy_priority_all
    sell_priority_set1 = sell_priority_all

    λ_2d = reshape(train_dual_set1, :, size(train_dual_set1, 4))
    Pout_2d = reshape(train_primal_set1, :, size(train_primal_set1, 4))
    P_decision_2d = reshape(train_P_decision_set1, :, size(train_P_decision_set1, 4))
    loc_prosumer_2d = reshape(loc_prosumer_set1, :, size(loc_prosumer_set1, 3))
    buy_priority_2d = reshape(buy_priority_set1, :, size(buy_priority_set1, 3))
    sell_priority_2d = reshape(sell_priority_set1, :, size(sell_priority_set1, 3))

    dv = DataFrame(λ_2d, :auto)
    pv = DataFrame(Pout_2d, :auto)
    p_decision_v = DataFrame(P_decision_2d, :auto)
    lp = DataFrame(loc_prosumer_2d, :auto)
    bp = DataFrame(buy_priority_2d, :auto)
    sp = DataFrame(sell_priority_2d, :auto)

    CSV.write("$(path)/DecisionVariable/dual_$(first)to$(last)sce.csv", dv)
    CSV.write("$(path)/DecisionVariable/primal_$(first)to$(last)sce.csv", pv)
    CSV.write("$(path)/DecisionVariable/P_decision_$(first)to$(last)sce.csv", p_decision_v)
    CSV.write("$(path)/location/location_prosumer_$(first)to$(last)sce.csv", lp)
    CSV.write("$(path)/DecisionVariable/buy_priority_$(first)to$(last)sce.csv", bp)
    CSV.write("$(path)/DecisionVariable/sell_priority_$(first)to$(last)sce.csv", sp)

    # For those 2D matrix, will update every 5 scenarios (storing info for all scenario)
    d_on = DataFrame(optimal_num=optimal_num[end-4:end])
    d_ex = DataFrame(execution_times=execution_times[end-4:end])
    lps = DataFrame(loc_pros_solar_all, :auto)
    pe = DataFrame(train_primal_error, :auto)
    pr = DataFrame(train_primal_residual, :auto)
    de = DataFrame(train_dual_error, :auto)
    dr = DataFrame(train_dual_residual, :auto)
    d_obj = DataFrame(train_obj, :auto)

    CSV.write("$(path)/location/location_user_solar_$(first)to$(last)sce.csv", lps)
    CSV.write("$(path)/location/optimal_iter_$(first)to$(last)sce.csv", d_on)
    CSV.write("$(path)/location/execution_time_$(first)to$(last)sce.csv", d_ex)
    CSV.write("$(path)/location/primal_error_$(first)to$(last)sce.csv", pe)
    CSV.write("$(path)/location/primal_residual_$(first)to$(last)sce.csv", pr)
    CSV.write("$(path)/location/dual_error_$(first)to$(last)sce.csv", de)
    CSV.write("$(path)/location/dual_residual_$(first)to$(last)sce.csv", dr)
    CSV.write("$(path)/location/objective_value_$(first)to$(last)sce.csv", d_obj)

    if infeasible == 1
        d_infeasible = DataFrame(infeasible_sce=infeasible_sce)
        CSV.write("$(path)/infeasible_sce/infeasible_sce_$(sce_start)to$(last)sce.csv", d_infeasible)
    end

    totalP2P = zeros(32,1000)
    costN = zeros(32,1000)
    costNEM = zeros(32,1000)
    costP2P = zeros(32,1000)
    costP2P_TNB = zeros(32,1000)
    reduce_P2P = zeros(32,1000)
    reduce_NEM = zeros(32,1000)

    totalP2P = pc[1:32,:]
    costN = pc[1*32+1:2*32,:]
    costNEM =  pc[2*32+1:3*32,:]
    costP2P =  pc[3*32+1:4*32,:]
    costP2P_TNB = pc[4*32+1:5*32,:]
    reduce_P2P = pc[5*32+1:6*32,:]
    reduce_NEM = pc[6*32+1:7*32,:]

    pc_df = DataFrame(pc, :auto)
    te_df = DataFrame(te, :auto)
    tp_df = DataFrame(totalP2P, :auto)
    cn_df = DataFrame(costN, :auto)
    cnem_df = DataFrame(costNEM, :auto)
    cp_df = DataFrame(costP2P, :auto)
    cpt_df = DataFrame(costP2P_TNB, :auto)
    rp_df = DataFrame(reduce_P2P, :auto)
    rn_df = DataFrame(reduce_NEM, :auto)

    CSV.write("$(path)/Profit/Prosumer_cost.csv", pc_df)
    CSV.write("$(path)/Profit/TNB_earning.csv", te_df)
    CSV.write("$(path)/Profit/cost from p2p only p2p.csv", tp_df)
    CSV.write("$(path)/Profit/cost from normal.csv", cn_df)
    CSV.write("$(path)/Profit/cost from nem.csv", cnem_df)
    CSV.write("$(path)/Profit/cost from p2p including tnb.csv", cp_df)
    CSV.write("$(path)/Profit/cost from p2p only tnb.csv", cpt_df)
    CSV.write("$(path)/Profit/reduction from p2p.csv", rp_df)
    CSV.write("$(path)/Profit/redction from nem.csv", rn_df)
    
    # For location of prosumers, store each scenario in separate folder (FOR CENTRALIZED COMPARISON)
    for i in first:last
        CSV.write("$(path)/location/location_prosumer_$(i).csv", DataFrame(loc_prosumer_all[:, :, i-first+1], :auto))
    end

    config["last_processed_index"] = last
    open("D:/Jacky/Python/ADMM_P2P_Python/dataset_collection/$(config["config name"]).json", "w") do f
        JSON.print(f, config, 4)
    end
    open("$(dir_path)/config.json", "w") do f
        JSON.print(f, config, 4)
    end
    if ledger_for_export !== nothing
        open("$(dir_path)/config_generalization.json", "w") do f
            JSON.print(f, ledger_for_export, 4) 
        end
    end

    cp(config["ADMM_ver"],"$(dir_path)/$(basename(config["ADMM_ver"]))", force=true)

    CSV.write("$(dir_path)/Param_Prosumer.csv", Param_Prosumer)
    CSV.write("$(dir_path)/Param_Grid.csv", Param_Grid)
end

function oneSave(primal, dual, P_decision, G_decision, execution_times, optimal_num, primal_error, dual_error, 
    primal_residual, dual_residual, obj_all, buy_priority, sell_priority, primal_all, dual_all, Pout_all, net_load, loc_prosumer)

    EOO = [execution_times optimal_num obj_all[end]]
    PBPB = [primal_error dual_error primal_residual dual_residual]
    Pout = Pout_all[:,:,optimal_num[1]]
    λ_toGO = dual_all[:,:,optimal_num[1]]

    λ_2d = reshape(dual_all, :, size(dual_all, 4))
    Pout_aux_2d = reshape(primal_all, :, size(primal_all, 4))
    Pout_2d = reshape(Pout_all, :, size(Pout_all, 4))

    dv = DataFrame(λ_2d, :auto)
    pav = DataFrame(Pout_aux_2d, :auto)
    pv = DataFrame(Pout_2d, :auto)

    current_datetime = now()
    current_date = Date(now())
    formatted_datetime = Dates.format(current_datetime, "yyyy-mm-dd_HHMMSS")
    file_dir = "D:/Jacky/Data Output/ADMM_P2P/OneSce"
    save_path = "$(file_dir)/Run_Julia_$(formatted_datetime)"

    if !isdir(save_path)
        mkpath(save_path)
        println("Created directory: $save_path")
    else
        println("Directory already exists: $save_path")
    end

    CSV.write("$(save_path)/EOpOb.csv", DataFrame(EOO,:auto), writeheader = false)
    CSV.write("$(save_path)/PBePBr.csv", DataFrame(PBPB,:auto), writeheader = false)
    CSV.write("$(save_path)/primal_last.csv", DataFrame(primal,:auto), writeheader = false)
    CSV.write("$(save_path)/dual_last.csv", DataFrame(dual,:auto), writeheader = false)
    CSV.write("$(save_path)/P_decision.csv", DataFrame(P_decision,:auto), writeheader = false)
    CSV.write("$(save_path)/G_decision.csv", DataFrame(hcat(G_decision...),:auto), writeheader = false)
    CSV.write("$(save_path)/buy_priority.csv", DataFrame(buy_priority,:auto), writeheader = false)
    CSV.write("$(save_path)/sell_priority.csv", DataFrame(sell_priority,:auto), writeheader = false)
    CSV.write("$(save_path)/Pout_last.csv", DataFrame(Pout,:auto), writeheader = false)
    CSV.write("$(save_path)/dual_toGO.csv", DataFrame(λ_toGO,:auto), writeheader = false)
    CSV.write("$(save_path)/dual_all.csv", dv)
    CSV.write("$(save_path)/primal_all.csv", pav)
    CSV.write("$(save_path)/Pout_all.csv", pv)
    CSV.write("$(save_path)/netload.csv", DataFrame(net_load, :auto), writeheader = false)
    CSV.write("$(save_path)/loc_prosumer.csv", DataFrame(loc_prosumer, :auto), writeheader = false)
    # npzwrite("$(save_path)/ui.npz", ui)
end

function savetoNPZ(first, last, train_primal, train_dual, train_P_decision, loc_pros_solar_all, loc_prosumer_all,
    execution_times, optimal_num, sce_start, sce_end, infeasible, infeasible_sce, train_primal_error, train_primal_residual,
    train_dual_error, train_dual_residual, train_obj, buy_priority_all, sell_priority_all, pc, te, dir_path, config, Param_Prosumer, Param_Grid,
    ledger_for_export=nothing)

    if isdir(dir_path)
        println("Folder exists: ", dir_path)
    else
        println("Folder does not exist, creating it.")
        mkpath(dir_path) 
        mkpath(joinpath(dir_path, "DecisionVariable"))
        mkpath(joinpath(dir_path, "optimal_iter"))
        mkpath(joinpath(dir_path, "location"))
        mkpath(joinpath(dir_path, "infeasible_sce"))
        mkpath(joinpath(dir_path, "Profit"))
    end

    # Decision Variable
    λ_2d = reshape(train_dual, :, size(train_dual, 4))
    Pout_2d = reshape(train_primal, :, size(train_primal, 4))
    P_decision_2d = reshape(train_P_decision, :, size(train_P_decision, 4))
    loc_prosumer_2d = reshape(loc_prosumer_all, :, size(loc_prosumer_all, 3))
    buy_priority_2d = reshape(buy_priority_all, :, size(buy_priority_all, 3))
    sell_priority_2d = reshape(sell_priority_all, :, size(sell_priority_all, 3))

    # Economic performance 
    totalP2P    = pc[1:32,:]
    costN       = pc[1*32+1:2*32,:]
    costNEM     = pc[2*32+1:3*32,:]
    costP2P     = pc[3*32+1:4*32,:]
    costP2P_TNB = pc[4*32+1:5*32,:]
    reduce_P2P  = pc[5*32+1:6*32,:]
    reduce_NEM  = pc[6*32+1:7*32,:]

    # update every 5 scenarios (storing info for all scenario)
    if isempty(glob("*.npz", "$(dir_path)/DecisionVariable")) # first saving attempt
        pe = train_primal_error
        pr = train_primal_residual
        de = train_dual_error
        dr = train_dual_residual
        ob = train_obj
        et = execution_times
        op = optimal_num
        lps = loc_pros_solar_all
        dv = λ_2d
        pv = Pout_2d
        pdv = P_decision_2d
        lp = loc_prosumer_2d
        bp = buy_priority_2d
        sp = sell_priority_2d

        pc_df   = pc 
        te_df   = te
        tp_df   = totalP2P
        cn_df   = costN
        cnem_df = costNEM
        cp_df   = costP2P
        cpt_df  = costP2P_TNB
        rp_df   = reduce_P2P
        rn_df   = reduce_NEM
    else
        pe = npzread("$(dir_path)/optimal_iter/primal_err.npz")
        pr = npzread("$(dir_path)/optimal_iter/primal_res.npz")
        de = npzread("$(dir_path)/optimal_iter/dual_err.npz")
        dr = npzread("$(dir_path)/optimal_iter/dual_res.npz")
        op = npzread("$(dir_path)/optimal_iter/conv_iter.npz")
        et = npzread("$(dir_path)/optimal_iter/runtime.npz")
        ob = npzread("$(dir_path)/optimal_iter/obj_var.npz")
        lps = npzread("$(dir_path)/location/location_user_solar.npz")
        lp = npzread("$(dir_path)/location/location_prosumer.npz")
        pv = npzread("$(dir_path)/DecisionVariable/primal.npz")
        dv = npzread("$(dir_path)/DecisionVariable/dual.npz")
        pdv = npzread("$(dir_path)/DecisionVariable/decision_var.npz")
        bp = npzread("$(dir_path)/DecisionVariable/buy_priority.npz")
        sp = npzread("$(dir_path)/DecisionVariable/sell_priority.npz")
        isfile("$(dir_path)/sce_collected_$(sce_start)to$(first-1).csv") ? rm(glob("sce_collected_$(sce_start)*","$(dir_path)")[1]) : 0
        pe = [pe; train_primal_error]
        pr = [pr; train_primal_residual]
        de = [de; train_dual_error]
        dr = [dr; train_dual_residual]
        ob = [ob; train_obj]
        et = [et; execution_times]
        op = [op; optimal_num]
        lps = [lps; loc_pros_solar_all]
        lp = [lp; loc_prosumer_2d]
        pv = [pv; Pout_2d]
        dv = [dv; λ_2d]
        pdv = [pdv; P_decision_2d]
        bp = [bp; buy_priority_2d]
        sp = [sp; sell_priority_2d]

        pc_df   = Matrix(CSV.read("$(dir_path)/Profit/Prosumer_cost.csv", DataFrame))
        te_df   = Matrix(CSV.read("$(dir_path)/Profit/TNB_earning.csv", DataFrame))
        tp_df   = Matrix(CSV.read("$(dir_path)/Profit/cost from p2p only p2p.csv", DataFrame))
        cn_df   = Matrix(CSV.read("$(dir_path)/Profit/cost from normal.csv", DataFrame))
        cnem_df = Matrix(CSV.read("$(dir_path)/Profit/cost from nem.csv", DataFrame))
        cp_df   = Matrix(CSV.read("$(dir_path)/Profit/cost from p2p including tnb.csv", DataFrame))
        cpt_df  = Matrix(CSV.read("$(dir_path)/Profit/cost from p2p only tnb.csv", DataFrame))
        rp_df   = Matrix(CSV.read("$(dir_path)/Profit/reduction from p2p.csv", DataFrame))
        rn_df   = Matrix(CSV.read("$(dir_path)/Profit/redction from nem.csv", DataFrame))

        pc_df[:, first:last]    = pc[:, first:last]
        te_df[:, first:last]    = te[:, first:last]
        tp_df[:, first:last]    = totalP2P[:, first:last]
        cn_df[:, first:last]    = costN[:, first:last]
        cnem_df[:, first:last]  = costNEM[:, first:last]
        cp_df[:, first:last]    = costP2P[:, first:last]
        cpt_df[:, first:last]   = costP2P_TNB[:, first:last]
        rp_df[:, first:last]    = reduce_P2P[:, first:last]
        rn_df[:, first:last]    = reduce_NEM[:, first:last]
    end

    CSV.write("$(dir_path)/sce_collected_$(sce_start)to$(last).csv", DataFrame([]))

    npzwrite("$(dir_path)/optimal_iter/primal_err.npz",pe)
    npzwrite("$(dir_path)/optimal_iter/primal_res.npz",pr)
    npzwrite("$(dir_path)/optimal_iter/dual_err.npz",de)
    npzwrite("$(dir_path)/optimal_iter/dual_res.npz",dr)
    npzwrite("$(dir_path)/optimal_iter/conv_iter.npz",op)
    npzwrite("$(dir_path)/optimal_iter/runtime.npz",et)
    npzwrite("$(dir_path)/optimal_iter/obj_var.npz",ob)
    npzwrite("$(dir_path)/location/location_user_solar.npz",lps)
    npzwrite("$(dir_path)/location/location_prosumer.npz",lp)
    npzwrite("$(dir_path)/DecisionVariable/primal.npz",pv)
    npzwrite("$(dir_path)/DecisionVariable/dual.npz",dv)
    npzwrite("$(dir_path)/DecisionVariable/decision_var.npz",pdv)
    npzwrite("$(dir_path)/DecisionVariable/buy_priority.npz",bp)
    npzwrite("$(dir_path)/DecisionVariable/sell_priority.npz",sp)

    if infeasible == 1
        d_infeasible = DataFrame(infeasible_sce=infeasible_sce)
        CSV.write("$(dir_path)/infeasible_sce/infeasible_sce_$(sce_start)to$(last)sce.csv", d_infeasible)
    end

    pc_df   = DataFrame(pc_df, :auto)
    te_df   = DataFrame(te_df, :auto)
    tp_df   = DataFrame(tp_df, :auto)
    cn_df   = DataFrame(cn_df, :auto)
    cnem_df = DataFrame(cnem_df, :auto)
    cp_df   = DataFrame(cp_df, :auto)
    cpt_df  = DataFrame(cpt_df, :auto)
    rp_df   = DataFrame(rp_df, :auto)
    rn_df   = DataFrame(rn_df, :auto)

    CSV.write("$(dir_path)/Profit/Prosumer_cost.csv", pc_df)
    CSV.write("$(dir_path)/Profit/TNB_earning.csv", te_df)
    CSV.write("$(dir_path)/Profit/cost from p2p only p2p.csv", tp_df)
    CSV.write("$(dir_path)/Profit/cost from normal.csv", cn_df)
    CSV.write("$(dir_path)/Profit/cost from nem.csv", cnem_df)
    CSV.write("$(dir_path)/Profit/cost from p2p including tnb.csv", cp_df)
    CSV.write("$(dir_path)/Profit/cost from p2p only tnb.csv", cpt_df)
    CSV.write("$(dir_path)/Profit/reduction from p2p.csv", rp_df)
    CSV.write("$(dir_path)/Profit/redction from nem.csv", rn_df)
    
    # For location of prosumers, store each scenario in separate folder (FOR CENTRALIZED COMPARISON)
    for i in first:last
        CSV.write("$(dir_path)/location/location_prosumer_$(i).csv", DataFrame(loc_prosumer_all[:, :, i-first+1], :auto))
    end

    config["last_processed_index"] = last
    open("D:/Jacky/Python/ADMM_P2P_Python/dataset_collection/$(config["config name"]).json", "w") do f
        JSON.print(f, config, 4)
    end
    open("$(dir_path)/config.json", "w") do f
        JSON.print(f, config, 4)
    end
    if ledger_for_export !== nothing
        open("$(dir_path)/config_generalization.json", "w") do f
            JSON.print(f, ledger_for_export, 4) 
        end
    end

    cp(config["ADMM_ver"],"$(dir_path)/$(basename(config["ADMM_ver"]))", force=true)

    CSV.write("$(dir_path)/Param_Prosumer.csv", Param_Prosumer)
    CSV.write("$(dir_path)/Param_Grid.csv", Param_Grid)
end


function send_notification(message)
    # Use the same unique topic name you chose in the app
    topic = "julia-testing" 
    url = "https://ntfy.sh/$topic"
    
    try
        HTTP.post(url, body=message)
        println("Notification sent!")
    catch e
        println("Failed to send notification: $e")
    end
end

function create_directory(dir_path)
    if isdir(dir_path)
        println("Folder exists: ", dir_path)
    else
        println("Folder does not exist, creating it.")
        mkpath(dir_path) 
        mkpath(joinpath(dir_path, "DecisionVariable"))
        mkpath(joinpath(dir_path, "optimal_iter"))
        mkpath(joinpath(dir_path, "location"))
        mkpath(joinpath(dir_path, "infeasible_sce"))
        mkpath(joinpath(dir_path, "Profit"))
    end
end

function generate_active_user(history_combinations, ledger_for_export, nb_prosumer, _num_user_active, sce, loc_prosumer)
    
    # 1. Calculate the absolute mathematical maximum for this specific user pool
    max_possible_combinations = binomial(nb_prosumer, _num_user_active)
    
    # 2. Count how many combinations OF THIS SIZE we have already generated
    # (This assumes history_combinations is a Set or Array of Tuples)
    current_count_for_size = count(comb -> length(comb) == _num_user_active, history_combinations)

    _rand_user_active = Int[]

    # 3. Apply your new logic: Check if we are allowed to repeat
    if current_count_for_size >= max_possible_combinations
        # We hit the limit! Just generate a random one and move on immediately.
        _rand_user_active = sample(1:nb_prosumer, _num_user_active, replace=false)
        
        # (Optional) You can print a little note so you know it's repeating
        # println("Size $_num_user_active maxed out ($max_possible_combinations). Allowing repeat.")
    else
        # We have NOT hit the limit. Force the system to find a unique one.
        while true
            _rand_user_active = sample(1:nb_prosumer, _num_user_active, replace=false)
            fingerprint = Tuple(sort(_rand_user_active))
            
            if !(fingerprint in history_combinations)
                push!(history_combinations, fingerprint) 
                break 
            end
        end
    end
    
    # 5. Map the users to the grid
    loc_prosumer[CartesianIndex.(_rand_user_active, _rand_user_active .+ 1)] .= 1

    # 6. Save to JSON ledger
    push!(ledger_for_export, Dict(
        "scenario" => sce,
        "num_users" => length(_rand_user_active),
        "active_users" => sort(_rand_user_active),
    ))

    return loc_prosumer, _rand_user_active, history_combinations, ledger_for_export
end