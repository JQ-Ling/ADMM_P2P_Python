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
    num_dec = Param[:num_dec]

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

    set_start_value.(P_c, Pout_aux[0*hour+1:1*hour, num_user])
    set_start_value.(P_d, Pout_aux[1*hour+1:2*hour, num_user])
    set_start_value.(P_buy, Pout_aux[2*hour+1:3*hour, num_user])
    set_start_value.(P_sell, Pout_aux[3*hour+1:4*hour, num_user])

    # @variable(Prosumer_model, B_charge[1:hour], Bin)  #limit charging or discharging
    @variable(Prosumer_model, P_out[i=1:num_dec*hour])

    ### constraints
    # Boundary constraints
    @constraint(Prosumer_model, lb_soc, P_CES .>= lb_CES[:, num_user])
    @constraint(Prosumer_model, ub_soc, P_CES .<= ub_CES[:, num_user])
    @constraint(Prosumer_model, lb_qc, P_c .>= lb_CESc[:, num_user])
    @constraint(Prosumer_model, ub_qc, P_c .<= ub_CES[:, num_user])
    @constraint(Prosumer_model, lb_qd, P_d .>= lb_CESc[:, num_user])
    @constraint(Prosumer_model, ub_qd, P_d .<= ub_CES[:, num_user])

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
    @constraint(Prosumer_model, [i in 1:hour-1],    P_CES[i+1] .== P_CES[i] + (η * P_c[i]) - (P_d[i] / η))
    @constraint(Prosumer_model,                     P_CES[1] .== P_CES[end] + (η * P_c[end]) - (P_d[end] / η))

    # To disable CES
    # @constraint(Prosumer_model, P_c .== 0)
    # @constraint(Prosumer_model, P_d .== 0)

    # Primal definition
    # @constraint(Prosumer_model, P_out .== [P_c; P_d; P_buy; P_sell; Pg_buy; Pg_sell])
    @constraint(Prosumer_model, P_out .== [P_c; P_d; P_buy; P_sell])

    # Objective 
    f_1 = sum(P_buy .* PI_buy[num_user, :] + P_sell .* PI_sell[num_user, :])
    f_2 = sum(beta_tnb .* (Pg_buy + Pg_sell))
    f_3 = sum(0.005 .* (P_c + P_d))

    # Proximal term
    Param[:pred_inj] ? fprox = sum(0.5 * Param[:mu] * (P_out - Param[:prediction][:, num_user]) .^ 2) : fprox = 0

    @objective(Prosumer_model, Min, f_1 + f_2 + f_3 + fprox
                                    + sum(-1 * lamda_u[:, num_user, num_iteration] .* P_out
                                          + 0.5 * rho_u * (Pout_aux[:, num_user] - P_out) .^ 2)) # define objective fucntion for subproblem

    optimize!(Prosumer_model) # calculate the problem
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
    num_dec = Param[:num_dec]
    η = Param[:efficiency_CES]
    num_ces = Param[:num_ces]
    CES_loc_matrix = Param[:CES_loc_matrix]
    Pg_CES0 = Param[:CES0]
    ub_CES = Param[:ub_CES]
    lb_CES = Param[:lb_CES]
    ub_CESc = Param[:ub_CESc]
    lb_CESc = Param[:lb_CESc]
    ub_CESd = Param[:ub_CESd]
    lb_CESd = Param[:lb_CESd]

    A_matrix = Param[:A_matrix]
    A_trans = Param[:A_trans]
    D_r = Param[:D_r]
    D_x = Param[:D_x]
    a_0 = Param[:a_0]

    dt = 0.5
    S_base = 10000.0  # From MATPOWER
    v_0 = 1.0 # as p.u.

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
    @variable(Grid_model, net_load_kW[i=1:hour, j=1:num_bus])
    @variable(Grid_model, P_out_aux[i=1:num_dec*hour, j=1:num_user] >= 0, start = P_out[i, j])
    @variable(Grid_model, lb_CES[i, j] <= PCES[i=1:hour, j=1:num_ces] <= ub_CES[i, j])
    @variable(Grid_model, lb_CESc[i, j] <= Pc[i=1:hour, j=1:num_ces] <= ub_CESc[i, j])
    @variable(Grid_model, lb_CESd[i, j] <= Pd[i=1:hour, j=1:num_ces] <= ub_CESd[i, j])

    # We use num_bus-1 (32) for injections and voltages (buses 2-33)
    @variable(Grid_model, P_inj[1:hour, 1:(num_bus-1)])
    @variable(Grid_model, Q_inj[1:hour, 1:(num_bus-1)])
    @variable(Grid_model, v[1:hour, 1:(num_bus-1)])
    p_net = Array{Any}(nothing, hour, num_bus - 1) 
    q_net = Array{Any}(nothing, hour, num_bus - 1)
     
    # P2P balance
    @constraint(Grid_model, sum(P_out_aux[2*hour+1:3*hour, :], dims=2) .== sum(P_out_aux[3*hour+1:4*hour, :], dims=2))

    # P2P trade hour
    @constraint(Grid_model, [i in 2*hour+1:2*hour+P2PTrade[1]], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, [i in 2*hour+1+P2PTrade[2]:3*hour], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, [i in 3*hour+1:3*hour+P2PTrade[1]], P_out_aux[i, :] .== 0)
    @constraint(Grid_model, [i in 3*hour+1+P2PTrade[2]:4*hour], P_out_aux[i, :] .== 0)

    # CES on Grid (to check SOC limit violation, Extn-LP formulation violation)
    @constraint(Grid_model, sum((η .* P_out_aux[0*hour+1:1*hour, :] - P_out_aux[1*hour+1:2*hour, :] ./ η), dims=2) .== sum((η .* Pc - Pd ./ η), dims=2))    # Ensure that the net energy charged/discharged decided by the users matches the net energy charged/discharged in the CES
    @constraint(Grid_model, PCES[1, :] .== Pg_CES0[1,:])
    @constraint(Grid_model, [i in 1:hour-1], PCES[i+1, :] .== PCES[i, :] + η .* Pc[i, :] - Pd[i,:] ./ η)
    @constraint(Grid_model, PCES[1, :] .== PCES[end, :] + η .* Pc[end, :] - Pd[end,:] ./ η)
    @constraint(Grid_model, [i in 1:hour-1], Pc[i+1, :] .<= (ub_CES[i, :] .- PCES[i, :]) ./ η)
    @constraint(Grid_model, Pc[1,:] .<= (ub_CES[1, :] .- Pg_CES0[1,:]) ./ η)
    @constraint(Grid_model, [i in 1:hour-1], Pd[i+1, :] .<= (PCES[i, :] .- lb_CES[i, :]) .* η)
    @constraint(Grid_model, Pd[1,:] .<= (Pg_CES0[1,:] .- lb_CES[1, :]) .* η)
    @constraint(Grid_model, Pd .<= ub_CESd .- (ub_CESd ./ ub_CESc) .* Pc)

    # =========================================================
    # Power Flow (LinDistFlow)
    # Assumed Global Dimensions:
    # hour = 48 (for 24 hours at 30-min intervals)
    # num_bus = 33
    # num_CES = (number of batteries)
    # =========================================================

    # net_load_kW size: (hour x num_bus) -> e.g., 48 x 33
    # P_load_bus: (hour x num_bus)
    # Pc, Pd: (hour x num_CES)
    # CES_loc_matrix: (num_CES x num_bus)
    # The multiplication (hour x num_CES) * (num_CES x num_bus) results in (hour x num_bus)
    net_load_kW = @expression(Grid_model, (P_load_bus ./ dt) .+ (((Pc .- Pd) ./ dt) * CES_loc_matrix))

    for t in 1:hour
        # Loop i from 1 to 32 (which represents branches and receiving buses 2 to 33)
        for i in 1:(num_bus-1)
            # p_net and q_net containers are size: (hour x 32)
            # We use i+1 to pull from columns 2:33 of the 33-column load matrices
            p_net[t, i] = @expression(Grid_model, -net_load_kW[t, i+1])
            q_net[t, i] = @expression(Grid_model, -(P_load_bus[t, i+1] / dt) * 0.5)
        end

        # p_net[t, :]   is a vector of size (32)
        # A_trans       is a matrix of size (32 x 32)
        # P_inj[t, :]   is a vector of size (32)
        @constraint(Grid_model, p_net[t, :] .== A_trans * P_inj[t, :])
        
        # q_net[t, :]   is a vector of size (32)
        # A_trans       is a matrix of size (32 x 32)
        # Q_inj[t, :]   is a vector of size (32)
        @constraint(Grid_model, q_net[t, :] .== A_trans * Q_inj[t, :])
        
        # v[t, :]       is a vector of size (32) -> represents voltage at buses 2 to 33
        # A_matrix      is a matrix of size (32 x 32)
        # a_0           is a vector of size (32) -> branch connection to the substation (Bus 1)
        # D_r, D_x      are Diagonal matrices of size (32 x 32) -> Resistance/Reactance
        @constraint(Grid_model, 
            A_matrix * v[t, :] .+ (v_0 .* a_0) .== 
            2 .* D_r * (P_inj[t, :] ./ S_base) .+ 2 .* D_x * (Q_inj[t, :] ./ S_base)
        )
    end

    @constraint(Grid_model, 0.95 .<= v .<= 1.05)
    @constraint(Grid_model, [i in 1:hour, j in 1:num_branch], P_inj[i, j] .>= -branch_limit[j])
    @constraint(Grid_model, [i in 1:hour, j in 1:num_branch], P_inj[i, j] .<= branch_limit[j])
    @constraint(Grid_model, [i in 1:hour, j in 1:num_branch], Q_inj[i, j] .>= -branch_limit[j])
    @constraint(Grid_model, [i in 1:hour, j in 1:num_branch], Q_inj[i, j] .<= branch_limit[j])

    # To disable CES
    # @constraint(Grid_model, Pc .== 0)
    # @constraint(Grid_model, Pd .== 0)

    f_1 = sum(P_out_aux[2*hour+1:3*hour, :] .* PI_buy' + P_out_aux[3*hour+1:4*hour, :] .* PI_sell')
    # f_2 = sum(1 .* (P_out_aux[4*hour+1:5*hour, :]  + P_out_aux[5*hour+1:6*hour, :]))
    # f_3 = sum(0.005 .* (P_out_aux[0*hour+1:1*hour, :] + P_out_aux[1*hour+1:2*hour, :]))
    # f_1 = 0
    f_2 = 0
    f_3 = 0

    # Proximal term
    Param[:pred_inj] ? fprox = sum(0.5 * Param[:mu] * (P_out_aux - Param[:prediction]) .^ 2) : fprox = 0

    @objective(Grid_model, Min, f_1 + f_2 + f_3 + fprox
             + sum(lamda_u[:, :, iteration_num] .* P_out_aux + 0.5 * rho_u * (P_out_aux - P_out) .^ 2)) # define objective fucntion for subproblem

    optimize!(Grid_model) # calculate the problem
    # solution_summary(Grid_model)
    obj = objective_value(Grid_model) 
    Pout_aux_val = value.(P_out_aux)    
    
    net_kW = value.(net_load_kW)
    V_results = value.(v)
    P_line_flows = value.(P_inj)
    Q_line_flows = value.(Q_inj)
    CES_SOC = value.(PCES)
    CES_charge = value.(Pc)
    CES_discharge = value.(Pd)

    # Combine results into a dictionary or named tuple for the return
    # This prevents the dimension mismatch error when joining 33-cols and 32-cols
    grid_results = (
        Net_Load = net_kW,
        Voltage = V_results,
        Flows = P_line_flows,
        CES_SOC = CES_SOC,
        CES_Charge = CES_charge,
        CES_Discharge = CES_discharge,
        Qlows = Q_line_flows,
    )

    return obj, Pout_aux_val, grid_results 
end

function load_bus(load_prosumer, loc_prosumer) # for computing net_load_hour for P_br
    bus_load = zeros(size(load_prosumer, 1), size(loc_prosumer, 2))
    bus_load = load_prosumer * loc_prosumer
    return bus_load
end
