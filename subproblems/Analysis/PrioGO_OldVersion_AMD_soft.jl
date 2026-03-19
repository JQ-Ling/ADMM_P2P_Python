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

    P_c_pred    = Param[:prediction][0*hour+1:1*hour, num_user]
    P_d_pred    = Param[:prediction][1*hour+1:2*hour, num_user]
    P_buy_pred  = Param[:prediction][2*hour+1:3*hour, num_user]
    P_sell_pred = Param[:prediction][3*hour+1:4*hour, num_user]
    episilon = 0.01

    P_load = Param[:load_demamd]
    PI_buy = Param[:buy_priority]
    PI_sell = Param[:sell_priority]

    B_load = zeros(size(P_load))
    B_load[findall(P_load .> 0)] .= 1 # 1 = TNL, 0 = TSE

    Prosumer_model = redirect_stdout(devnull) do
        Model(Gurobi.Optimizer)
    end
    ######## Allocate the cores/threads, 1 core = 2 threads for multithreading ##########
    JuMP.set_optimizer_attribute(Prosumer_model, "OutputFlag", 0)
    JuMP.set_optimizer_attribute(Prosumer_model, "Threads", 2)

    set_silent(Prosumer_model)
    @variable(Prosumer_model, nload[i=1:hour])
    @variable(Prosumer_model, P_buy[i=1:hour] >= 0)
    @variable(Prosumer_model, P_sell[i=1:hour] >= 0)
    @variable(Prosumer_model, Pg_buy[i=1:hour] >= 0)
    @variable(Prosumer_model, Pg_sell[i=1:hour] >= 0)
    @variable(Prosumer_model, lb_CES[i, num_user] <= P_CES[i=1:hour] <= ub_CES[i, num_user])
    @variable(Prosumer_model, lb_CESc[i, num_user] <= P_c[i=1:hour] <= ub_CESc[i, num_user])
    @variable(Prosumer_model, lb_CESd[i, num_user] <= P_d[i=1:hour] <= ub_CESd[i, num_user])
    # @variable(Prosumer_model, P_CES[i=1:hour] >= 0)
    # @variable(Prosumer_model, P_c[i=1:hour] >= 0)
    # @variable(Prosumer_model, P_d[i=1:hour] >= 0)

    set_start_value.(P_c, Pout_aux[0*hour+1:1*hour, num_user])
    set_start_value.(P_d, Pout_aux[1*hour+1:2*hour, num_user])
    set_start_value.(P_buy, Pout_aux[2*hour+1:3*hour, num_user])
    set_start_value.(P_sell, Pout_aux[3*hour+1:4*hour, num_user])

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

    @constraint(Prosumer_model, P_c .>= P_c_pred .- episilon)
    @constraint(Prosumer_model, P_c .<= P_c_pred .+ episilon)
    # @constraint(Prosumer_model, P_d .>= P_d_pred .- episilon)
    # @constraint(Prosumer_model, P_d .<= P_d_pred .+ episilon)
    # @constraint(Prosumer_model, P_buy .>= P_buy_pred .- episilon)
    # @constraint(Prosumer_model, P_buy .<= P_buy_pred .+ episilon)
    # @constraint(Prosumer_model, P_sell .>= P_sell_pred .- episilon)
    # @constraint(Prosumer_model, P_sell .<= P_sell_pred .+ episilon)

    # P2P trade hour
    @constraint(Prosumer_model, [i in 1:P2PTrade[1]], P_buy[i] .== 0)
    @constraint(Prosumer_model, [i in P2PTrade[2]:hour], P_buy[i] .== 0)
    @constraint(Prosumer_model, [i in 1:P2PTrade[1]], P_sell[i] .== 0)
    @constraint(Prosumer_model, [i in P2PTrade[2]:hour], P_sell[i] .== 0)

    # Net load clearing
    @constraint(Prosumer_model, nload .== P_load[:, num_user] + P_c - P_d)
    @constraint(Prosumer_model, Pg_buy + P_buy .== nload .* B_load[:, num_user])
    @constraint(Prosumer_model, Pg_sell + P_sell .== nload .* (B_load[:, num_user] .- 1)) # binary - 1 is to let the constraint take SE (-ve) and convert it into +ve

    # SOC of CES (Extn-LP formulation)
    @constraint(Prosumer_model, [i in 1:hour-1],    P_c[i+1] .<= (ub_CES[i, num_user] .- P_CES[i]) ./ η)
    @constraint(Prosumer_model,                     P_c[1] .<= (ub_CES[1, num_user] .- P_CES0[num_user]) ./ η)
    @constraint(Prosumer_model, [i in 1:hour-1],    P_d[i+1] .<= (P_CES[i] .- lb_CES[i, num_user]) .* η)
    @constraint(Prosumer_model,                     P_d[1] .<= (P_CES0[num_user] .- lb_CES[1, num_user]) .* η)
    @constraint(Prosumer_model,                     P_d .<= ub_CESd[:, num_user] .- (ub_CESd[:, num_user] ./ ub_CESc[:, num_user]) .* P_c)
    @constraint(Prosumer_model,                     P_CES[1] == P_CES0[num_user])
    @constraint(Prosumer_model,                     P_CES[end] == P_CES[1])
    @constraint(Prosumer_model, [i in 1:hour-1],    P_CES[i+1] .== P_CES[i] + (η * P_c[i]) - (P_d[i] / η))
    @constraint(Prosumer_model,                     P_CES[1] .== P_CES[end] + (η * P_c[end]) - (P_d[end] / η))

    # Primal definition
    # @constraint(Prosumer_model, P_out .== [P_c; P_d; P_buy; P_sell; Pg_buy; Pg_sell])
    @constraint(Prosumer_model, P_out .== [P_c; P_d; P_buy; P_sell])
    # @constraint(Prosumer_model, P_out .== Pout_aux[:, num_user] + chg_p)

    # Objective 
    f_1 = sum(P_buy .* PI_buy[num_user, :] + P_sell .* PI_sell[num_user, :])
    f_2 = sum(beta_tnb .* (Pg_buy + Pg_sell))
    f_3 = sum(0.005 .* (P_c + P_d))

    @objective(Prosumer_model, Min, f_1 + f_2 + f_3
                                    + sum(-1 * lamda_u[:, num_user, num_iteration] .* P_out
                                          + 0.5 * rho_u * (Pout_aux[:, num_user] - P_out) .^ 2)) # define objective fucntion for subproblem

    optimize!(Prosumer_model) # calculate the problem
    # println("User $(num_user) - Global solution? : $(is_solved_and_feasible(Prosumer_model; allow_local = false))")

    try
        obj_Prosumer = objective_value(Prosumer_model) # obtain the optimal value of objective function, cost
        Grid_buy = value.(Pg_buy) # use value.() to get result
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

        # Pout = [Charge; Discharge; P2P_buy; P2P_sell; Grid_buy; Grid_sell]
        Pout = [Charge; Discharge; P2P_buy; P2P_sell]
        P_decision = [Grid_buy; Grid_sell; bat_lv; Charge; Discharge; P2P_buy; P2P_sell; P2P_sell]  #add X1 and X2 binaries into primal to allow partial linear relaxation on subproblem
        return obj_Prosumer, P_decision, Pout # return objective function and decision variable
    catch e
        obj_Prosumer, P_decision, Pout = NaN, NaN, false
        println("User $(num_user) - Global solution? : $(is_solved_and_feasible(Prosumer_model; allow_local = false))")
        return obj_Prosumer, P_decision, Pout # return objective function and decision variable
    end
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

    episilon = 0.01

    P_load_bus = load_bus(P_load, loc_prosumer)

    B_load = zeros(size(P_load))
    B_load[findall(P_load .> 0)] .= 1 # 1 = TNL, 0 = TSE

    Grid_model = redirect_stdout(devnull) do
        Model(Gurobi.Optimizer)
    end

    ############ allocate the cores/threads, 1 core = 2 threads for multithreading ############
    JuMP.set_optimizer_attribute(Grid_model, "OutputFlag", 0)
    JuMP.set_optimizer_attribute(Grid_model, "Threads", 16)

    set_silent(Grid_model)
    @variable(Grid_model, net_load[i=1:hour, j=1:num_branch]) ## need to modify this constraint if implement multiple prosumers in 1 bus
    @variable(Grid_model, net_load_hour[i=1:hour, j=1:num_bus])
    @variable(Grid_model, P_br[i=1:hour, j=1:num_branch])
    # @variable(Grid_model, P_out_aux[i=1:4*hour, j=1:num_user], start = P_out[i, j])
    @variable(Grid_model, P_out_aux[i=1:4*hour, j=1:num_user] >= 0, start = P_out[i, j])

    # Consensus primal variable
    # @constraint(Grid_model, P_out_aux .== P_out + chg_p)

    @constraint(Grid_model, [i in 0*hour+1:1*hour+P2PTrade[1]], P_out_aux[i, :] .>= Param[:prediction][i, :] .- episilon)
    @constraint(Grid_model, [i in 0*hour+1:1*hour+P2PTrade[1]], P_out_aux[i, :] .<= Param[:prediction][i, :] .+ episilon)
    # @constraint(Grid_model, [i in 1*hour+1:2*hour+P2PTrade[1]], P_out_aux[i, :] .>= Param[:prediction][i, :] .- episilon)
    # @constraint(Grid_model, [i in 1*hour+1:2*hour+P2PTrade[1]], P_out_aux[i, :] .<= Param[:prediction][i, :] .+ episilon)
    # @constraint(Grid_model, [i in 2*hour+1:3*hour+P2PTrade[1]], P_out_aux[i, :] .>= Param[:prediction][i, :] .- episilon)
    # @constraint(Grid_model, [i in 2*hour+1:3*hour+P2PTrade[1]], P_out_aux[i, :] .<= Param[:prediction][i, :] .+ episilon)
    # @constraint(Grid_model, [i in 3*hour+1:4*hour+P2PTrade[1]], P_out_aux[i, :] .>= Param[:prediction][i, :] .- episilon)
    # @constraint(Grid_model, [i in 3*hour+1:4*hour+P2PTrade[1]], P_out_aux[i, :] .<= Param[:prediction][i, :] .+ episilon)

    # P2P trade hour
    @constraint(Grid_model, [i in 2*hour+1:2*hour+P2PTrade[1]], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, [i in 2*hour+1+P2PTrade[2]:3*hour], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, [i in 3*hour+1:3*hour+P2PTrade[1]], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, [i in 3*hour+1+P2PTrade[2]:4*hour], P_out_aux[i, :] .== 0)

    # Power Flow
    @constraint(Grid_model, net_load .== [sum(P_out_aux[0*hour+1:1*hour, :], dims=2) zeros(hour, num_branch - 1)] - [sum(P_out_aux[1*hour+1:2*hour, :], dims=2) zeros(hour, num_branch - 1)])
    @constraint(Grid_model, net_load_hour .== [zeros(hour, 1) net_load] + P_load_bus)
    @constraint(Grid_model, P_br .== -((net_load_hour ./ 0.5)* ptdf'))
    @constraint(Grid_model, [i in 1:hour, j in 1:num_branch], P_br[i, j] .>= -branch_limit[j])
    @constraint(Grid_model, [i in 1:hour, j in 1:num_branch], P_br[i, j] .<= branch_limit[j])

    # P2P balance
    # @constraint(Grid_model, sum(P_load, dims=2) .+ sum(P_out_aux[0*hour+1:1*hour, :], dims=2) .- sum(P_out_aux[1*hour+1:2*hour, :], dims=2) .- (sum(P_out_aux[2*hour+1:3*hour, :], dims=2) + sum(P_out_aux[4*hour+1:5*hour, :], dims=2)) .+ (sum(P_out_aux[3*hour+1:4*hour, :], dims=2) + sum(P_out_aux[5*hour+1:6*hour, :], dims=2)) .== 0)
    @constraint(Grid_model, sum(P_out_aux[2*hour+1:3*hour, :], dims=2) .== sum(P_out_aux[3*hour+1:4*hour, :], dims=2))

    f_1 = sum(P_out_aux[2*hour+1:3*hour, :] .* PI_buy' + P_out_aux[3*hour+1:4*hour, :] .* PI_sell')
    # f_2 = sum(1 .* (P_out_aux[4*hour+1:5*hour, :]  + P_out_aux[5*hour+1:6*hour, :]))
    # f_3 = sum(0.005 .* (P_out_aux[0*hour+1:1*hour, :] + P_out_aux[1*hour+1:2*hour, :]))
    # f_1 = 0
    f_2 = 0
    f_3 = 0

    @objective(Grid_model, Min, f_1 + f_2 + f_3
             + sum(lamda_u[:, :, iteration_num] .* P_out_aux + 0.5 * rho_u * (P_out_aux - P_out) .^ 2)) # define objective fucntion for subproblem

    optimize!(Grid_model) # calculate the problem
    # solution_summary(Grid_model)
    obj = objective_value(Grid_model) # obtain the optimal value of objective function
    Pout_aux = value.(P_out_aux)    # use value.() to get result
    net_load_branch = value.(net_load_hour)
    P_br = value.(P_br)

    # Pout_aux[2*hour+1:3*hour, :] .= Pout_aux[2*hour+1:3*hour, :] .* B_load
    # Pout_aux[3*hour+1:4*hour, :] .= Pout_aux[3*hour+1:4*hour, :] .* (B_load .- 1)

    P_decision = [net_load_branch; P_br zeros(hour,1)]

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

# subproblem for prosumers with predictions
function Subproblem_Prosumer_prediction(Param::Dict{}, Pout_aux, num_user, lamda_u, num_iteration) # solve subproblem for each user
    println("New Prosumer Subproblem with AI Prediction")
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

    P_buy = Pout_aux[2*hour+1:3*hour, num_user]
    P_sell = Pout_aux[3*hour+1:4*hour, num_user]

    Prosumer_model = Model(Gurobi.Optimizer)

    ######## Allocate the cores/threads, 1 core = 2 threads for multithreading ##########
    JuMP.set_optimizer_attribute(Prosumer_model, "Threads", 2)
    # JuMP.set_optimizer_attribute(Prosumer_model, "OutputFlag", 1)

    set_silent(Prosumer_model)
    @variable(Prosumer_model, nload[i=1:hour])
    # @variable(Prosumer_model, P_buy[i=1:hour] >= 0)
    # @variable(Prosumer_model, P_sell[i=1:hour] >= 0)
    @variable(Prosumer_model, Pg_buy[i=1:hour] >= 0)
    @variable(Prosumer_model, Pg_sell[i=1:hour] >= 0)
    @variable(Prosumer_model, lb_CES[i, num_user] <= P_CES[i=1:hour] <= ub_CES[i, num_user])
    @variable(Prosumer_model, lb_CESc[i, num_user] <= P_c[i=1:hour] <= ub_CESc[i, num_user])
    @variable(Prosumer_model, lb_CESd[i, num_user] <= P_d[i=1:hour] <= ub_CESd[i, num_user])

    # set_start_value.(P_c, Pout_aux[0*hour+1:1*hour, num_user])
    # set_start_value.(P_d, Pout_aux[1*hour+1:2*hour, num_user])
    # set_start_value.(P_buy, Pout_aux[2*hour+1:3*hour, num_user])
    # set_start_value.(P_sell, Pout_aux[3*hour+1:4*hour, num_user])

    # @variable(Prosumer_model, B_charge[1:hour], Bin)  #limit charging or discharging
    # @variable(Prosumer_model, P_out[i=1:4*hour])
    # @variable(Prosumer_model, chg_p[i=1:4*hour])
    @variable(Prosumer_model, P_out[i=1:4*hour])
    @variable(Prosumer_model, chg_p[i=1:4*hour])

    ### constraints
    # P2P trade hour
    @constraint(Prosumer_model, [i in 1:P2PTrade[1]], P_buy[i] .== 0)
    @constraint(Prosumer_model, [i in P2PTrade[2]:hour], P_buy[i] .== 0)
    @constraint(Prosumer_model, [i in 1:P2PTrade[1]], P_sell[i] .== 0)
    @constraint(Prosumer_model, [i in P2PTrade[2]:hour], P_sell[i] .== 0)

    # Net load clearing
    @constraint(Prosumer_model, nload .== P_load[:, num_user] + P_c - P_d)
    @constraint(Prosumer_model, Pg_buy + P_buy .== nload .* B_load[:, num_user])
    @constraint(Prosumer_model, Pg_sell + P_sell .== nload .* (B_load[:, num_user] .- 1)) # binary - 1 is to let the constraint take SE (-ve) and convert it into +ve

    # SOC of CES (Extn-LP formulation)
    @constraint(Prosumer_model, [i in 1:hour-1], P_c[i+1] .<= (ub_CES[:, num_user] .- P_CES[i]) ./ η)
    @constraint(Prosumer_model, P_c[1] .<= (ub_CES[:, num_user] .- P_CES0[num_user]) ./ η)
    @constraint(Prosumer_model, [i in 1:hour-1], P_d[i+1] .<= (P_CES[i] .- lb_CES[:, num_user]) .* η)
    @constraint(Prosumer_model, P_d[1] .<= (P_CES0[num_user] .- lb_CES[:, num_user]) .* η)
    @constraint(Prosumer_model, P_d .<= ub_CESd[:, num_user] .- (ub_CESd[:, num_user] ./ ub_CESc[:, num_user]) .* P_c)
    @constraint(Prosumer_model, P_CES[1] == P_CES0[num_user])
    @constraint(Prosumer_model, P_CES[end] == P_CES[1])
    @constraint(Prosumer_model, [i in 1:hour-1], P_CES[i+1] .== P_CES[i] + (η * P_c[i]) - (P_d[i] / η))
    @constraint(Prosumer_model, P_CES[1] .== P_CES[end] + (η * P_c[end]) - (P_d[end] / η))

    # Primal definition
    # @constraint(Prosumer_model, P_out .== [P_c; P_d; P_buy; P_sell; Pg_buy; Pg_sell])
    @constraint(Prosumer_model, P_out .== [P_c; P_d; P_buy; P_sell])
    @constraint(Prosumer_model, P_out .== Pout_aux[:, num_user] + chg_p)

    # Objective 
    f_1 = sum(P_buy .* PI_buy[num_user, :] + P_sell .* PI_sell[num_user, :])
    f_2 = sum(beta_tnb .* (Pg_buy + Pg_sell))
    f_3 = sum(0.005 .* (P_c + P_d))

    @objective(Prosumer_model, Min, f_1 + f_2 + f_3
                                    + sum(-1 * lamda_u[:, num_user, num_iteration] .* P_out
                                          +
                                          0.5 * rho_u * (Pout_aux[:, num_user] - P_out) .^ 2)) # define objective fucntion for subproblem

    optimize!(Prosumer_model) # calculate the problem
    obj_Prosumer = objective_value(Prosumer_model) # obtain the optimal value of objective function, cost
    Grid_buy = value.(Pg_buy) # use value.() to get result
    Grid_sell = value.(Pg_sell)
    bat_lv = value.(P_CES)
    Charge = value.(P_c)
    Discharge = value.(P_d)
    # remove small numerical error 
    Charge[findall(x->x<1e-4, Charge)] .= 0
    Discharge[findall(x->x<1e-4, Discharge)] .= 0

    P2P_buy = value.(P_buy)
    P2P_sell = value.(P_sell)
    P2P_buy = P_buy
    P2P_sell = P_sell

    # B_charge = value.(B_charge)
    # Pout = [Charge; Discharge; P2P_buy; P2P_sell; Grid_buy; Grid_sell]
    Pout = [Charge; Discharge; P2P_buy; P2P_sell]
    P_decision = [Grid_buy; Grid_sell; bat_lv; Charge; Discharge; P2P_buy; P2P_sell; P2P_sell]  #add X1 and X2 binaries into primal to allow partial linear relaxation on subproblem

    return obj_Prosumer, P_decision, Pout # return objective function and decision variable
end