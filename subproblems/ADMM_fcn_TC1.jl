# subproblem for prosumers
function Subproblem_Prosumer(Param::Dict{}, Pout_aux, num_user, lamda_u, num_iteration) # solve subproblem for each user

    ub_CES = Param[:ub_CES]
    lb_CES = Param[:lb_CES]
    ub_CESc = Param[:ub_CESc]
    lb_CESc = Param[:lb_CESc]
    ub_CESd = Param[:ub_CESd]
    lb_CESd = Param[:lb_CESd]
    hour = Param[:hour]
    beta_tnb = Param[:beta_tnb]
    P_CES0 = Param[:CES0]
    P2PTrade = Param[:P2PTrade]
    η = Param[:efficiency_CES]
    # η = 1
    
    P_load = Param[:load_demamd]
    PI_buy = Param[:buy_priority]
    PI_sell = Param[:sell_priority]

    B_load = zeros(size(P_load))
    B_load[findall(P_load .> 0)] .= 1 # 1 = TNL, 0 = TSE

    Prosumer_model = Model(Gurobi.Optimizer)

    ######## Allocate the cores/threads, 1 core = 2 threads for multithreading ##########
    JuMP.set_optimizer_attribute(Prosumer_model, "Threads", 2)
    # JuMP.set_optimizer_attribute(Prosumer_model, "OutputFlag", 1)

    set_silent(Prosumer_model)
    @variable(Prosumer_model, nload[i=1:hour])
    @variable(Prosumer_model, P_buy[i=1:hour] >= 0)
    @variable(Prosumer_model, P_sell[i=1:hour] >= 0)
    @variable(Prosumer_model, Pg_buy[i=1:hour] >= 0)
    @variable(Prosumer_model, Pg_sell[i=1:hour] >= 0)
    @variable(Prosumer_model, P_CES[i=1:hour] >= 0)
    @variable(Prosumer_model, P_c[i=1:hour] >= 0)
    @variable(Prosumer_model, P_d[i=1:hour] >= 0)

    # @variable(Prosumer_model, 0 <= P_buy[i=1:hour] <= 1e10 .* B_load[i, num_user])
    # @variable(Prosumer_model, 0 <= Pg_buy[i=1:hour] <= 1e10 .* B_load[i, num_user])
    # @variable(Prosumer_model, 0 <= P_sell[i=1:hour] <= 1e10 .* (1 .- B_load[i, num_user]))
    # @variable(Prosumer_model, 0 <= Pg_sell[i=1:hour] <= 1e10 .* (1 .- B_load[i, num_user]))

    # set_start_value.(P_c, Pout_aux[0*hour+1:1*hour, num_user])
    # set_start_value.(P_d, Pout_aux[1*hour+1:2*hour, num_user])
    # set_start_value.(P_buy, Pout_aux[2*hour+1:3*hour, num_user])
    # set_start_value.(P_sell, Pout_aux[3*hour+1:4*hour, num_user])

    # @variable(Prosumer_model, B_charge[1:hour], Bin)  #limit charging or discharging
    @variable(Prosumer_model, P_out[i=1:4*hour])
    # @variable(Prosumer_model, chg_p[i=1:4*hour])

    ### constraints
    # Boundary constraints
    @constraint(Prosumer_model, lb_soc, P_CES .>= lb_CES[:, num_user])
    @constraint(Prosumer_model, ub_soc, P_CES .<= ub_CES[:, num_user])
    @constraint(Prosumer_model, lb_qc, P_c .>= lb_CESc[:, num_user])
    @constraint(Prosumer_model, ub_qc, P_c .<= ub_CES[:, num_user])
    @constraint(Prosumer_model, lb_qd, P_d .>= lb_CESc[:, num_user])
    @constraint(Prosumer_model, ub_qd, P_d .<= ub_CES[:, num_user])

    # P2P trade hour
    @constraint(Prosumer_model, PbuyTrade_1[i in 1:P2PTrade[1]], P_buy[i] .== 0)
    @constraint(Prosumer_model, PbuyTrade_2[i in P2PTrade[2]:hour], P_buy[i] .== 0)
    @constraint(Prosumer_model, PsellTrade_1[i in 1:P2PTrade[1]], P_sell[i] .== 0)
    @constraint(Prosumer_model, PsellTrade_2[i in P2PTrade[2]:hour], P_sell[i] .== 0)

    # Net load balance
    @constraint(Prosumer_model, loadbal, nload .== P_load[:, num_user] + P_c - P_d)
    @constraint(Prosumer_model, buybal, Pg_buy + P_buy .== nload .* B_load[:, num_user])
    @constraint(Prosumer_model, sellbal, Pg_sell + P_sell .== nload .* (B_load[:, num_user] .- 1)) # binary - 1 is to let the constraint take SE (-ve) and convert it into +ve

    # SOC of CES (Extn-LP formulation)
    @constraint(Prosumer_model, ExLP1_1[i in 1:hour-1],     P_c[i+1] .<= (ub_CES[i, num_user] .- P_CES[i]) ./ η)
    @constraint(Prosumer_model, ExLP1_2,                    P_c[1] .<= (ub_CES[1, num_user] .- P_CES0[num_user]) ./ η)
    @constraint(Prosumer_model, ExLP2_1[i in 1:hour-1],     P_d[i+1] .<= (P_CES[i] .- lb_CES[i, num_user]) .* η)
    @constraint(Prosumer_model, ExLP2_2,                    P_d[1] .<= (P_CES0[num_user] .- lb_CES[1, num_user]) .* η)
    @constraint(Prosumer_model, ExLP3,                      P_d .<= ub_CESd[:, num_user] .- (ub_CESd[:, num_user] ./ ub_CESc[:, num_user]) .* P_c)
    @constraint(Prosumer_model, soc_start,                  P_CES[1] == P_CES0[num_user])
    @constraint(Prosumer_model, soc_end_equal_start,        P_CES[end] == P_CES[1])
    @constraint(Prosumer_model, soc_bal[i in 1:hour-1],     P_CES[i+1] .== P_CES[i] + (η * P_c[i]) - (P_d[i] / η))
    @constraint(Prosumer_model, soc_wrap,                   P_CES[1] .== P_CES[end] + (η * P_c[end]) - (P_d[end] / η))

    # Primal definition
    @constraint(Prosumer_model, P_out .== [P_c; P_d; P_buy; P_sell])
    # @constraint(Prosumer_model, P_out .== Pout_aux[:, num_user] + chg_p)

    # Objective 
    f_1 = sum(P_buy .* PI_buy[num_user, :] + P_sell .* PI_sell[num_user, :])
    f_2 = sum(beta_tnb .* (Pg_buy + Pg_sell))
    f_3 = sum(0.005 .* (P_c + P_d))

    @objective(Prosumer_model, Min, f_1 + f_2 + f_3
                                    + sum(-1 * lamda_u[:, num_user, num_iteration] .* P_out
                                          +
                                          0.5 * rho_u * (Pout_aux[:, num_user] - P_out) .^ 2)) 

    optimize!(Prosumer_model) # calculate the problem
    println("Model found global solution?: $(is_solved_and_feasible(Prosumer_model; allow_local = false))")
    println("Model found optimal dual?: $(is_solved_and_feasible(Prosumer_model; dual = true))")

    # obtain the optimal value of objective function, decicison variables
    obj_Prosumer = objective_value(Prosumer_model) 
    Grid_buy = value.(Pg_buy) 
    Grid_sell = value.(Pg_sell)
    bat_lv = value.(P_CES)
    Charge = value.(P_c)
    Discharge = value.(P_d)
    P2P_buy = value.(P_buy)
    P2P_sell = value.(P_sell)
    # B_charge = value.(B_charge)

    # remove small numerical error 
    Charge[findall(x->x<1e-4, Charge)] .= 0
    Discharge[findall(x->x<1e-4, Discharge)] .= 0

    # Concatenate all decision variables
    Pout = [Charge; Discharge; P2P_buy; P2P_sell]
    P_decision = [Grid_buy; Grid_sell; bat_lv; Charge; Discharge; P2P_buy; P2P_sell; P2P_sell] 
    
    # # Obtain dual variables for inequality constraints
    # duals_ExLP1_1               = dual.(ExLP1_1)
    # duals_ExLP1_2               = dual.(ExLP1_2)
    # duals_ExLP2_1               = dual.(ExLP2_1)
    # duals_ExLP2_2               = dual.(ExLP2_2)
    # duals_ExLP3                 = dual.(ExLP3)

    # duals_lb_soc                = dual.(lb_soc)
    # duals_ub_soc                = dual.(ub_soc)
    # duals_lb_qc                 = dual.(lb_qc)
    # duals_ub_qc                 = dual.(ub_qc)
    # duals_lb_qd                 = dual.(lb_qd)
    # duals_ub_qd                 = dual.(ub_qd)

    # duals_PbuyTrade_1           = dual.(PbuyTrade_1)
    # duals_PbuyTrade_2           = dual.(PbuyTrade_2)
    # duals_PsellTrade_1          = dual.(PsellTrade_1)
    # duals_PsellTrade_2          = dual.(PsellTrade_2)
    # duals_loadbal               = dual.(loadbal)
    # duals_buybal                = dual.(buybal)
    # duals_sellbal               = dual.(sellbal)
    # duals_soc_bal               = dual.(soc_bal)
    # duals_soc_wrap              = dual.(soc_wrap)
    # duals_soc_start             = dual.(soc_start)
    # duals_soc_end_equal_start   = dual.(soc_end_equal_start)

    # duals_ExLP1     = vcat(duals_ExLP1_2, duals_ExLP1_1)
    # duals_ExLP2     = vcat(duals_ExLP2_2, duals_ExLP2_1)
    # # duals_soc_bal   = vcat(duals_soc_bal, duals_soc_wrap)
    # duals_soc_bal   = vcat(duals_soc_wrap, duals_soc_bal)
    
    # duals_soc_start = duals_soc_start * ones(hour,1)
    # duals_soc_end_equal_start = duals_soc_end_equal_start * ones(hour,1)

    # duals_PbuyTrade  = zeros(hour)
    # duals_PsellTrade = zeros(hour)
    # for t in range(1, P2PTrade[1])
    #     duals_PbuyTrade[t]  += duals_PbuyTrade_1[t]
    #     duals_PsellTrade[t] += duals_PsellTrade_1[t]
    # end
    # for t in range(P2PTrade[2], hour)
    #     duals_PbuyTrade[t]  += duals_PbuyTrade_2[t]
    #     duals_PsellTrade[t] += duals_PsellTrade_2[t]
    # end

    # ui = [duals_ExLP1'; duals_ExLP2'; duals_ExLP3'; duals_lb_qc'; duals_ub_qc'; duals_lb_qd'; duals_lb_qd'; duals_lb_soc'; duals_ub_soc';
    #         duals_PbuyTrade'; duals_PsellTrade'; duals_loadbal'; duals_buybal'; duals_sellbal'; duals_soc_bal'; duals_soc_start'; duals_soc_end_equal_start';]
    #         # duals_PbuyTrade'; duals_PsellTrade'; duals_loadbal'; duals_loadbal'; duals_loadbal'; duals_soc_bal';]
    
    # return obj_Prosumer, P_decision, Pout, ui
    return obj_Prosumer, P_decision, Pout
end


# subproblem for grid operator
function Subproblem_Grid_Operator(Param::Dict{}, P_out, lamda_u, iteration_num) # solve subproblem for each user
    hour = Param[:hour]
    ptdf = Param[:ptdf]
    num_bus = Param[:num_bus]
    num_branch = Param[:num_branch]
    branch_limit = Param[:branch_limit]
    P_load = Param[:load_demamd]
    num_user = Param[:num_user]
    loc_prosumer = Param[:loc_prosumer]
    PI_buy = Param[:buy_priority]
    PI_sell = Param[:sell_priority]
    P2PTrade = Param[:P2PTrade]

    P_load_bus = load_bus(P_load, loc_prosumer)

    Grid_model = Model(Gurobi.Optimizer)

    ############ allocate the cores/threads, 1 core = 2 threads for multithreading ############
    JuMP.set_optimizer_attribute(Grid_model, "Threads", 16)

    set_silent(Grid_model)
    @variable(Grid_model, net_load[i=1:hour, j=1:num_branch]) ## need to modify this constraint if implement multiple prosumers in 1 bus
    @variable(Grid_model, net_load_hour[i=1:hour, j=1:num_bus])
    @variable(Grid_model, P_br[i=1:hour, j=1:num_branch])
    # @variable(Grid_model, P_out_aux[i=1:4*hour, j=1:num_user], start = P_out[i, j])
    @variable(Grid_model, P_out_aux[i=1:4*hour, j=1:num_user])
    # @variable(Grid_model, chg_p[i=1:4*hour, j=1:num_user])

    # P2P trade hour
    @constraint(Grid_model, PbuyTrade_1[i in 2*hour+1:2*hour+P2PTrade[1]], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, PbuyTrade_2[i in 2*hour+1+P2PTrade[2]:3*hour], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, PsellTrade_1[i in 3*hour+1:3*hour+P2PTrade[1]], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, PsellTrade_2[i in 3*hour+1+P2PTrade[2]:4*hour], P_out_aux[i, :] .== 0)

    # @constraint(Grid_model, P_out_aux .== P_out + chg_p)
    @constraint(Grid_model, nload_bus, net_load .== [sum(P_out_aux[0*hour+1:1*hour, :], dims=2) zeros(hour, num_branch - 1)] - [sum(P_out_aux[1*hour+1:2*hour, :], dims=2) zeros(hour, num_branch - 1)])
    @constraint(Grid_model, net_load_hour .== [zeros(hour, 1) net_load] + P_load_bus)
    @constraint(Grid_model, P_br .== -((net_load_hour ./ 0.5)* ptdf'))

    @constraint(Grid_model, PtradeBal, sum(P_out_aux[2*hour+1:3*hour, :], dims=2) .== sum(P_out_aux[3*hour+1:4*hour, :], dims=2))
    @constraint(Grid_model, br_limit_1[i in 1:hour, j in 1:num_branch], P_br[i, j] .>= -branch_limit[j])
    @constraint(Grid_model, br_limit_2[i in 1:hour, j in 1:num_branch], P_br[i, j] .<= branch_limit[j])

    f_1 = sum(P_out_aux[2*hour+1:3*hour, :] .* PI_buy' + P_out_aux[3*hour+1:4*hour, :] .* PI_sell')
    # f_1 = 0

    @objective(Grid_model, Min, f_1 + sum(lamda_u[:, :, iteration_num] .* P_out_aux + 0.5 * rho_u * (P_out_aux - P_out) .^ 2)) # define objective fucntion for subproblem

    optimize!(Grid_model) # calculate the problem
    obj = objective_value(Grid_model)
    Pout_aux = value.(P_out_aux)
    net_load_branch = value.(net_load_hour)
    P_br = value.(P_br)

    P_decision = [net_load_branch; P_br zeros(hour,1)]

    # # Obtain dual variables for inequality constraints
    # duals_br_limit_1            = dual.(br_limit_1)
    # duals_br_limit_2            = dual.(br_limit_2)
    # duals_PtradeBal_hourly      = dual.(PtradeBal)
    # duals_nload_bus             = dual.(nload_bus)
    # # duals_PbuyTrade_1           = dual.(PbuyTrade_1)
    # # duals_PbuyTrade_2           = dual.(PbuyTrade_2)
    # # duals_PsellTrade_1          = dual.(PsellTrade_1)
    # # duals_PsellTrade_2          = dual.(PsellTrade_2)

    # duals_PtradeBal             = repeat(duals_PtradeBal_hourly, 1, num_user)

    # # duals_PbuyTrade  = zeros(hour)
    # # duals_PsellTrade = zeros(hour)
    # # for t in range(1, P2PTrade[1])
    # #     duals_PbuyTrade[t]  += duals_PbuyTrade_1[t]
    # #     duals_PsellTrade[t] += duals_PsellTrade_1[t]
    # # end
    # # for t in range(P2PTrade[2], hour)
    # #     duals_PbuyTrade[t]  += duals_PbuyTrade_2[t]
    # #     duals_PsellTrade[t] += duals_PsellTrade_2[t]
    # # end

    # uig = cat(duals_br_limit_1, duals_br_limit_2, duals_PtradeBal; dims=3)
    # uig = permutedims(uig, (3,1,2))

    # return obj, Pout_aux, P_decision, uig # return objective function and decision variable
    return obj, Pout_aux, P_decision # return objective function and decision variable
end

#######################################################################################################
#Function to generate individual changing charging demand 1 for 30EVs
function scegeneration(data)
    # Set a specific seed value
    seed_value = 666
    Random.seed!(seed_value)

    initial_demand1 = data

    num_elements_1 = size(initial_demand1, 1)
    num_elements_2 = size(initial_demand1, 2)
    num_combinations = 5000
    element_range_1 = [0:minimum(initial_demand1)*1.1-minimum(initial_demand1):minimum(initial_demand1)*1.5-minimum(initial_demand1) for _ in 1:num_elements_1]
    element_range_2 = [0:minimum(initial_demand1)*1.1-minimum(initial_demand1):minimum(initial_demand1)*1.5-minimum(initial_demand1) for _ in 1:num_elements_2]

    combinations = []
    temp_comb = []

    # Add a DEEP COPY of the initial matrix as the first combination
    push!(combinations, initial_demand1)

    # Generate additional combinations
    while length(combinations) < num_combinations
        if ndims(initial_demand1) == 1
            combination = [initial_demand1[i] + rand(range) for (i, range) in enumerate(element_range_1)]
            push!(combinations, combination)
        else
            for col in 1:num_elements_1
                combination = [initial_demand1[col, i] + rand(range) for (i, range) in enumerate(element_range_2)]
                push!(temp_comb, combination)
            end
            matrix_result = hcat(temp_comb...)'
            push!(combinations, matrix_result)
            temp_comb = []
        end
    end

    combinations_array = combinations #convert into array from set

    # # Print the first few generated combinations
    # for i in 1:min(10, num_combinations)
    #     println("Combination $i: $(combinations_array[i])\n")
    # end

    return combinations_array
end

function load_bus(load_prosumer, loc_prosumer) # for computing net_load_hour for P_br
    bus_load = zeros(size(load_prosumer, 1), size(loc_prosumer, 2))
    bus_load = load_prosumer * loc_prosumer
    return bus_load
end

