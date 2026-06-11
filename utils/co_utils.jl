using Printf, Statistics, Plots

function PrioConversion(Prio, Excess, netload, BS)
    nb_prosumer = size(Prio, 1)  # number of prosumers
    nb_hour = size(Prio, 2)
    intPrio = copy(Prio')
    sortPrio = sort(intPrio, dims=2)
    
    for i in 1:nb_hour
        int = 1
        for j in 1:nb_prosumer
            println(" ")
            for k in 1:nb_prosumer
                if (Excess[i] > 0) 
                    if BS == 0 #buying priority
                        if (netload[i,k] > 0)
                            if (sortPrio[i,j] == intPrio[i,k])
                                intPrio[i,k] = int
                                int += 1
                            end
                        else
                            intPrio[i,k] = 0
                        end
                    elseif BS == 1 #selling priority
                        if (netload[i,k] < 0)
                            # @printf("%f ==  %f	\n", sortPrio[i,j], intPrio[i,k])
                            if (sortPrio[i,j] == intPrio[i,k])
                                # println("   ")
                                # print("int  ")
                                # println(int)
                                # print("hour:    ")
                                # println(i)
                                intPrio[i,k] = int
                                int += 1
                            end
                        else
                            intPrio[i,k] = 0
                        end
                    end
                else 
                    intPrio[i,k] = 0
                end
            end
        end
    end
    return intPrio
end

function CommercialTariff(Power)
    TarrifPrice = [0.435 0.509]; TarrifRange = 200; TotalCost = 0
    if (Power > TarrifRange)
        TotalCost += TarrifRange * TarrifPrice[1];
        Power = Power - TarrifRange;
        TotalCost += Power * TarrifPrice[2];
    else
        TotalCost += Power * TarrifPrice[1];
    end
    return TotalCost
end

function ResidentialTariff(Power)
    # TarrifPrice = [0.218 0.334 0.516 0.546 0.571]; 
    TarrifPrice = 0.5443*ones(1,5); 
    TarrifRange = [200 100 300 300]; TotalCost = 0; i = 1
    # for j in 1:4
    #     J += 1
    #     if (Power > 0)
    #         TotalCost += TarrifRange[j] * TarrifPrice[j];

    #         Power = Power - TarrifRange[j];

    #         if (Power < 0)
    #             TotalCost -= TarrifRange[j] * TarrifPrice[j];

    #             Power = Power + TarrifRange[j];
    #             break;
    #         end
    #     end
    # end
    
    # TotalCost += Power * TarrifPrice[J];

    while (Power - sum(TarrifRange[1:i]) > 0)
        i += 1
        if i == 5
            break
        end
    end
    
    TotalCost = sum(TarrifPrice[1:i-1] .* TarrifRange[1:i-1]) + (Power - sum(TarrifRange[1:i-1])) * TarrifPrice[i]
    
    return TotalCost
end

function IndustrialTariff(Power)
    TarrifPrice = [0.380 0.441]; TarrifRange = 200; TotalCost = 0
    if (Power > TarrifRange)
        TotalCost += TarrifRange * TarrifPrice[1];
        Power = Power - TarrifRange;
        TotalCost += Power * TarrifPrice[2];
    else
        TotalCost += Power * TarrifPrice[1];
    end
    return TotalCost
end

function ProfitCal(Result_Grid_buy, Result_Grid_sell, Result_P2P_buy, Result_P2P_sell)

    tnb_cost            = [0.5443, 0.15]
    hour                = DATA[:hour]
    num_user            = DATA[:num_user]
    P2PTrade            = DATA[:P2PTrade]
    buy_bp              = DATA[:buy_bp]
    sell_bp             = DATA[:sell_bp]
    power_consumption   = DATA[:raw_load]
    net_load            = DATA[:P_load]'

    final_buy_price = sum(buy_bp, dims=1) / num_user
    final_sell_price = sum(sell_bp, dims=1) / num_user

    totalPower = sum(power_consumption, dims=1)
    totalP2P = sum((Result_P2P_buy[P2PTrade[1]:P2PTrade[2], :] .* final_buy_price'[P2PTrade[1]:P2PTrade[2]]) - (Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* final_sell_price'[P2PTrade[1]:P2PTrade[2]])
                    + (Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1]) - (Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[2]), dims = 1)
    totalTNB = zeros(num_user)
    for t in 1:hour
        if (t < P2PTrade[1] || t > P2PTrade[2]) 
            totalTNB[:] += Result_Grid_buy[t,:]
        end
    end

    totalNEM = sum(net_load', dims=1)

    costN = []
    costP2P = []
    costP2P_TNB = []
    costNEM = []
    reduce_P2P = []
    reduce_NEM = []

    for i in 1:num_user 
        append!(costN, ResidentialTariff(totalPower[i]))

        append!(costP2P_TNB, ResidentialTariff(totalTNB[i]))
        append!(costP2P, costP2P_TNB[i] + totalP2P[i])

        append!(costNEM, ResidentialTariff(totalNEM[i]))
        costNEM[findall(x->x<0, costNEM)] .= 0
    end

    for i in 1:num_user
        append!(reduce_P2P, ((costN[i] - costP2P[i]) / costN[i]) * 100)
        append!(reduce_NEM, ((costN[i] - costNEM[i]) / costN[i]) * 100)
    end

    # TNBearn_P2P = sum(Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* (buy_bp'[P2PTrade[1]:P2PTrade[2], :] .- sell_bp'[P2PTrade[1]:P2PTrade[2], :]))
    TNBearn_P2P = sum(Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* (final_buy_price'[P2PTrade[1]:P2PTrade[2]] .- final_sell_price'[P2PTrade[1]:P2PTrade[2]]))
    TNBearn_Normal = sum(Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1] * 0.15)
    TNBearn_Selling = sum(Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* (0.35 - tnb_cost[2]))

    TNBearning = ((TNBearn_P2P + TNBearn_Normal + TNBearn_Selling) * 1) + (sum(costP2P_TNB) * 0.15);

    return costP2P, TNBearning
end

function plot_all(CES_lv, CES_Charge, CES_Discharge, bus_voltage, Result_P_br, Result_Q_br, BranchLimit)
    num_CES = size(CES_lv, 2)
    CES_cap = CES_lv[1,:]' .* 2
    CES_SOC = copy(CES_lv)
    CES_SOC ./= CES_cap
    p = plot(CES_SOC[:,1], 
                label="CES 1, Capacity: $(round(CES_cap[1], digits=2)) kWh", 
                ylabel="SOC", 
                xlabel="Time", 
                # yscale=:log10, 
                title="State of Charge of CES on Grid", 
                # titlefontsize=8,
                size=(600, 400))
    for i in 2:num_CES
        plot!(p, CES_SOC[:,i], label="CES $i, Capacity: $(round(CES_cap[i], digits=2)) kWh")
    end
    display(p)

    CES_net_charge = CES_Charge - CES_Discharge
    p2 = plot(CES_net_charge[:,1], 
                label="CES 1", 
                ylabel="Net Charge (kWh)", 
                xlabel="Time", 
                # yscale=:log10, 
                title="Net Charge Operation of CES on Grid", 
                titlefontsize=8,
                size=(600, 400))
    for i in 2:num_CES
        plot!(p2, CES_net_charge[:,i], label="CES $i")
    end
    display(p2)

    num_bus = size(bus_voltage, 2)
    p3 = plot(bus_voltage[:,1], 
                ylabel="Voltage (p.u.)", 
                xlabel="Time", 
                # yscale=:log10, 
                title="Voltage Profile of Grid, Limit: [0.95, 1.05] p.u.", 
                titlefontsize=8,
                size=(600, 400),
                legend = :none)
    for i in 2:num_bus
        plot!(p3, bus_voltage[:,i], legend = :none)
    end
    display(p3)

    max_power = maximum(abs.(Result_P_br), dims=1)
    pass = sum(max_power .< BranchLimit') != 0
    p4 = plot(max_power', 
                label="P", 
                ylabel="Active Power (kW)", 
                xlabel="Branch", 
                yscale=:log10, 
                title="Active Power Flow on Branches (Pass: $pass)", 
                # titlefontsize=8,
                size=(600, 400))
    plot!(p4, BranchLimit, label="Branch Limit", linestyle=:dash, linecolor=:red)
    display(p4)

    max_reactive_power = maximum(abs.(Result_Q_br), dims=1)
    pass = sum(max_reactive_power .< BranchLimit') != 0
    p5 = plot(max_reactive_power', 
                label="Q", 
                ylabel="Reactive Power (kVAR)", 
                xlabel="Branch", 
                yscale=:log10, 
                title="Reactive Power Flow on Branches (Pass: $pass)", 
                # titlefontsize=8,
                size=(600, 400))
    plot!(p5, BranchLimit, label="Branch Limit", linestyle=:dash, linecolor=:red)
    display(p5)
end