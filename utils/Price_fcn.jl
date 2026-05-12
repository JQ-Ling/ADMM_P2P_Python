using Printf

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

function ResultPrint(Prosumer_decision, Grid_decision, buy_priority, sell_priority, total_excess, net_load, buy_bp, sell_bp, tnb_cost, power_consumption, SolarScaler, BatteryCap, P2PTrade, Param_Grid)
    println("#######################################")
    println("Printing Result")
    println("#######################################")

    nb_prosumer = size(power_consumption_data, 2)  # number of prosumers
    # nb_prosumer = 5
    nb_hour = size(power_consumption_data, 1)  # time
    hour = nb_hour
    Result_Grid_buy = Prosumer_decision[0*hour+1:1*hour, :]
    Result_Grid_sell = Prosumer_decision[1*hour+1:2*hour, :]
    Result_bat_lv = Prosumer_decision[2*hour+1:3*hour, :]
    Result_Charge = Pout_aux[0*hour+1:1*hour, :]
    Result_Discharge = Pout_aux[1*hour+1:2*hour, :]
    Result_P2P_buy = Pout_aux[2*hour+1:3*hour, :]
    Result_P2P_sell = Pout_aux[3*hour+1:4*hour, :]
    Result_B_charge = Prosumer_decision[7*hour+1:8*hour, :]

    bus_voltage     = Grid_decision[2]
    Result_P_br     = Grid_decision[3]
    CES_lv          = Grid_decision[4]
    CES_Charge      = Grid_decision[5]
    CES_Discharge   = Grid_decision[6]
    Result_Q_br     = Grid_decision[7]

    BranchLimit = Param_Grid[:branch_limit]

    final_buy_price = sum(buy_bp, dims=1) / 32
    final_sell_price = sum(sell_bp, dims=1) / 32

    NetLoad = net_load' + Result_Charge - Result_Discharge
    # NetLoad = net_load'

    nbBuyPrio = PrioConversion(buy_priority, total_excess, NetLoad, 0)
    nbSellPrio = PrioConversion(sell_priority, total_excess, NetLoad, 1)

    # (1) -> Buying and Selling amount including Priority
    # ------------------------------------------------------//
    println("Priority")
    println("------------------------------------------------------")

    for i in 1:nb_hour
        # if total_excess[i] == 0
        #     break
        # end
        if (i <= P2PTrade[1] || i >= P2PTrade[2]) 
            continue
        end
        println("Time Step ", i)
        println()

        print("		")
        println("Net Load	Charge  Discharge   Net Load (Bat)	Buy from P2P	Sell to P2P	Buy from TNB	Sell to TNB")

        for j in 1:nb_prosumer

            @printf("Prosumer %d	    %.2f	%.2f	%.2f		%.2f		", j , net_load[j,i], Result_Charge[i,j], Result_Discharge[i,j], NetLoad[i,j])

            # Print Buy amount and Priority
            @printf("%.2f  (%d)	", Result_P2P_buy[i,j], nbBuyPrio[i,j])

            # Print Sell amount and Priority
            @printf("%.2f  (%d)	   ", Result_P2P_sell[i,j], nbSellPrio[i,j])

            @printf("%.2f		   %.2f\n", Result_Grid_buy[i,j], Result_Grid_sell[i,j])
        end

        println("-----------------------------------------------------------------------------")
    end

    # Monthly pricing for prosumers
    println("Pricing for each prosumer (Day)")
    println("------------------------------------------------------")

    print("		")
    println("Power		Net Load        Total Cost        NEM            P2P | From P2P 	From TNB")

    totalPower = sum(power_consumption, dims=1)
    # totalPower *= 30
    # totalP2P = sum((Result_P2P_buy[P2PTrade[1]:P2PTrade[2], :] .* buy_bp'[P2PTrade[1]:P2PTrade[2], :]) - (Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* sell_bp'[P2PTrade[1]:P2PTrade[2], :])
    #             + (Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1]) - (Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[2]), dims=1)
    totalP2P = sum((Result_P2P_buy[P2PTrade[1]:P2PTrade[2], :] .* final_buy_price'[P2PTrade[1]:P2PTrade[2]]) - (Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* final_sell_price'[P2PTrade[1]:P2PTrade[2]])
                    + (Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1]) - (Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[2]), dims = 1)
    totalTNB = zeros(nb_prosumer)
    for t in 1:nb_hour
        if (t < P2PTrade[1] || t > P2PTrade[2]) 
            totalTNB[:] += Result_Grid_buy[t,:]
            # print(t)
        end
    end
    # totalP2P *= 30
    # totalTNB *= 30
    totalNEM = sum(net_load', dims=1)
    # totalNEM *= 30

    costN = []
    costP2P = []
    costP2P_TNB = []
    costNEM = []

    for i in 1:nb_prosumer 
        prosumerType = first(names(power_consumption_data)[i])
        # normal tariff
        # if prosumerType == 'C'
        #     append!(costN, CommercialTariff(totalPower[i]))
        # elseif prosumerType == 'I'
        #     append!(costN, IndustrialTariff(totalPower[i]))
        # elseif prosumerType == 'R'
        #     append!(costN, ResidentialTariff(totalPower[i]))
        # end
        append!(costN, ResidentialTariff(totalPower[i]))

        # P2P tariff
        # if prosumerType == 'C'
        #     append!(costP2P_TNB, CommercialTariff(totalTNB[i]))
        #     append!(costP2P, CommercialTariff(totalTNB[i]) + totalP2P[i])
        # elseif prosumerType == 'I'
        #     append!(costP2P_TNB, IndustrialTariff(totalTNB[i]))
        #     append!(costP2P, IndustrialTariff(totalTNB[i]) + totalP2P[i])
        # elseif prosumerType == 'R'
        #     append!(costP2P_TNB, ResidentialTariff(totalTNB[i]))
        #     append!(costP2P, ResidentialTariff(totalTNB[i]) + totalP2P[i])
        # end
        append!(costP2P_TNB, ResidentialTariff(totalTNB[i]))
        append!(costP2P, costP2P_TNB[i] + totalP2P[i])

        # NEM tariff
        # if prosumerType == 'C'
        #     append!(costNEM, CommercialTariff(totalNEM[i]))
        # elseif prosumerType == 'I'
        #     append!(costNEM, IndustrialTariff(totalNEM[i]))
        # elseif prosumerType == 'R'
        #     append!(costNEM, ResidentialTariff(totalNEM[i]))
        # end
        append!(costNEM, ResidentialTariff(totalNEM[i]))
        costNEM[findall(x->x<0, costNEM)] .= 0

        println("Prosumer ", i, "	",
        string(@sprintf("%.2f", totalPower[i]), "		",
                @sprintf("%.2f", totalNEM[i]), "		",
                @sprintf("%.2f", costN[i]), "		",
                @sprintf("%.2f", costNEM[i]), "		",
                @sprintf("%.2f | %.2f          	%.2f", costP2P[i], totalP2P[i], costP2P_TNB[i])))

    end

    println("------------------------------------------------------")
    println("Average Profit / Costing")
    println("------------------------------------------------------")
    println("		", "P2P          ", "NEM	", "Normal    ", "Reduction - P2P (%)	", "Reduction - NEM (%)	")

    for i in 1:nb_prosumer
        # println(names(power_consumption_data)[i],"   ",
        println("Prosumer ", i,"   ",
        string(@sprintf("%.2f", costP2P[i]),"         ",
                @sprintf("%.2f", costNEM[i]),"        ",
                @sprintf("%.2f", costN[i]),"          ",
                @sprintf("%.2f", ((costN[i] - costP2P[i]) / costN[i]) * 100),"           ",
                @sprintf("%.2f", ((costN[i] - costNEM[i]) / costN[i]) * 100)))
    end

    println("------------------------------------------------------")
    println("Profit for TNB (month)")
    println("------------------------------------------------------")

    # index_s = 1
    # index_b = 1
    # remain_b = 0
    # TNBearn_P2P = 0
    # for i in 1:nb_hour
    #     for j in 1:nb_prosumer
    #         if remain_b > 0
    #             remain_s = Result_P2P_sell[i, findall(nbSellPrio[i,:]==index_s)] - remain_b
    #             if remain_s >= 0 # remain buy amount used up one shot
    #                 TNBearn_P2P += sum(remain_b.* (buy_bp'[i, findall(nbBuyPrio[i,:]==index_b)] .- sell_bp'[i, findall(nbSellPrio[i,:]==index_s)]))
    #                 index_b += 1
    #             end
    #             while (remain_s < 0)
    #                 TNBearn_P2P += sum(Result_P2P_sell[i, findall(nbSellPrio[i,:]==index_s)] .* (buy_bp'[i, findall(nbBuyPrio[i,:]==index_b)] .- sell_bp'[i, findall(nbSellPrio[i,:]==index_s)]))
    #                 index_s += 1
    #                 remain_b = -remain_s
    #                 remain_s = Result_P2P_sell[i, findall(nbSellPrio[i,:]==index_s)] - remain_b
    #             end
    #         end
    #         remain_s = Result_P2P_sell[i, findall(nbSellPrio[i,:]==index_s)] - Result_P2P_buy[i, findall(nbBuyPrio[i,:]==index_b)]
    #         if remain_s <= 0 # sell amount used up one shot
    #             TNBearn_P2P += sum(Result_P2P_sell[i, findall(nbSellPrio[i,:]==index_s)] .* (buy_bp'[i, findall(nbBuyPrio[i,:]==index_b)] .- sell_bp'[i, findall(nbSellPrio[i,:]==index_s)]))
    #             index_b += 1
    #             index_s += 1
    #         end
    #         while (remain_s > 0)
    #             TNBearn_P2P += sum(Result_P2P_sell[i, findall(nbSellPrio[i,:]==index_s)] .* (buy_bp'[i, findall(nbBuyPrio[i,:]==index_b)] .- sell_bp'[i, findall(nbSellPrio[i,:]==index_s)]))
    #             index_b += 1
    #             remain_s = Result_P2P_sell[i, findall(nbSellPrio[i,:]==index_s)] - Result_P2P_buy[i, findall(nbBuyPrio[i,:]==index_b)]
    #         end
    #         if remain_s < 0
    #             index_b -= 1
    #             remain_b = -remain_s
    #         end
    #     end
    # end

    # TNBearn_P2P = sum(Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* (buy_bp'[P2PTrade[1]:P2PTrade[2], :] .- sell_bp'[P2PTrade[1]:P2PTrade[2], :]))
    TNBearn_P2P = sum(Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* (final_buy_price'[P2PTrade[1]:P2PTrade[2]] .- final_sell_price'[P2PTrade[1]:P2PTrade[2]]))
    TNBearn_Normal = sum(Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1] * 0.15)
    TNBearn_Selling = sum(Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* (0.35 - tnb_cost[2]))

    # TNBearning = ((TNBearn_P2P + TNBearn_Normal + TNBearn_Selling) * 30) + (sum(costP2P_TNB) * 0.15);
    TNBearning = ((TNBearn_P2P + TNBearn_Normal + TNBearn_Selling) * 1) + (sum(costP2P_TNB) * 0.15);
    TNBearning_normal = sum(costN) * 0.15

    println("With P2P ")
    println("-----------------------------")
    println("Profit from:")
    # println("P2P                    : ", TNBearn_P2P * 30)
    # println("Normal (Trading Hour)  : ", TNBearn_Normal * 30)
    # println("Normal (Non Trading Hour): ", sum(costP2P_TNB) * 0.15)
    # println("Sell off purchased electricity : ", TNBearn_Selling * 30)

    println("P2P                    : ", TNBearn_P2P * 1)
    println("Normal (Trading Hour)  : ", TNBearn_Normal * 1)
    println("Normal (Non Trading Hour): ", sum(costP2P_TNB) * 0.15)
    println("Sell off purchased electricity : ", TNBearn_Selling * 1)

    println("")

    println("Normal ")
    println("-----------------------------")
    println("Profit from:")
    println("Normal tariff cost             : ", TNBearning_normal)

    println("")

    println("NEM ")
    println("-----------------------------")
    println("Profit from:")
    println("Normal tariff cost             : ", sum(costNEM) * 0.15)

    println("")

    println("Total Profit with P2P       : ", TNBearning)
    println("Total Profit with NEM       : ", sum(costNEM) * 0.15)
    println("Total Profit Normal         : ", TNBearning_normal)

    println("")

    println("Solar Installed = ", SolarScaler, " kWp")
    println("Battery Capacity = ", BatteryCap, " kWh")

    println("")

    # # Toal net load for every hour
    # println("Time Step		Total Power Consumption			Total Net Load  ")
    # totalPowerhour = sum(power_consumption, dims=2)
    # totalLoadhour = sum(NetLoad, dims=2)
    # for i in 1: nb_hour
    #     println("$i			$(totalPowerhour[i])					$(totalLoadhour[i])")
    # end

    # # DC power flow (radial bus)
    # println("Branch Data without and with Battery")
    # println("------------------------------------------------------")
    # for i in 1:nb_hour
    #     println("Time Step $i")
    #     println("Branch #	From bus	To bus  	From Bus P (kW)")
    #     for j in 1: nb_prosumer
    #         println("$j		$j		$(j+1)		$(round(Result_P_br[i,j], digits = 2))")
    #     end
    #     println("-----------------------------------------------------------------------------")
    # end

    num_CES = size(CES_lv, 2)
    CES_cap = CES_lv[1,:]'
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

    max_power = maximum(Result_P_br, dims=1)
    p4 = plot(max_power', 
                label="P", 
                ylabel="Active Power (kW)", 
                xlabel="Branch", 
                yscale=:log10, 
                title="Active Power Flow on Branches", 
                # titlefontsize=8,
                size=(600, 400))
    plot!(p4, BranchLimit, label="Branch Limit", linestyle=:dash, linecolor=:red)
    display(p4)

    max_reactive_power = maximum(Result_Q_br, dims=1)
    p5 = plot(max_reactive_power', 
                label="Q", 
                ylabel="Reactive Power (kVAR)", 
                xlabel="Branch", 
                yscale=:log10, 
                title="Reactive Power Flow on Branches", 
                # titlefontsize=8,
                size=(600, 400))
    plot!(p5, BranchLimit, label="Branch Limit", linestyle=:dash, linecolor=:red)
    display(p5)
end

function ProfitCal(Prosumer_decision, buy_priority, sell_priority, total_excess, net_load, buy_bp, sell_bp, tnb_cost, power_consumption, SolarScaler, BatteryCap, P2PTrade)
    # println("#######################################")
    # println("Printing Result")
    # println("#######################################")

    nb_prosumer = size(power_consumption_data, 2)  # number of prosumers
    # nb_prosumer = 5
    nb_hour = size(power_consumption_data, 1)  # time
    hour = nb_hour
    Result_Grid_buy = Prosumer_decision[0*hour+1:1*hour, :]
    Result_Grid_sell = Prosumer_decision[1*hour+1:2*hour, :]
    Result_bat_lv = Prosumer_decision[2*hour+1:3*hour, :]
    Result_Charge = Pout_aux[0*hour+1:1*hour, :]
    Result_Discharge = Pout_aux[1*hour+1:2*hour, :]
    Result_P2P_buy = Pout_aux[2*hour+1:3*hour, :]
    Result_P2P_sell = Pout_aux[3*hour+1:4*hour, :]
    Result_B_charge = Prosumer_decision[7*hour+1:8*hour, :]

    # Result_net_load = Grid_decision[0*hour+1:1*hour, :]
    # Result_P_br = Grid_decision[1*hour+1:2*hour, :]
    final_buy_price = sum(buy_bp, dims=1) / 32
    final_sell_price = sum(sell_bp, dims=1) / 32

    NetLoad = net_load' + Result_Charge - Result_Discharge
    # NetLoad = net_load'

    totalPower = sum(power_consumption, dims=1)
    # totalPower *= 30
    # totalP2P = sum((Result_P2P_buy[P2PTrade[1]:P2PTrade[2], :] .* buy_bp'[P2PTrade[1]:P2PTrade[2], :]) - (Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* sell_bp'[P2PTrade[1]:P2PTrade[2], :])
    #             + (Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1]) - (Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[2]), dims=1)
    totalP2P = sum((Result_P2P_buy[P2PTrade[1]:P2PTrade[2], :] .* final_buy_price'[P2PTrade[1]:P2PTrade[2]]) - (Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* final_sell_price'[P2PTrade[1]:P2PTrade[2]])
                    + (Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1]) - (Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[2]), dims = 1)
    totalTNB = zeros(nb_prosumer)
    for t in 1:nb_hour
        if (t < P2PTrade[1] || t > P2PTrade[2]) 
            totalTNB[:] += Result_Grid_buy[t,:]
            # print(t)
        end
    end
    # totalP2P *= 30
    # totalTNB *= 30
    totalNEM = sum(net_load', dims=1)
    # totalNEM *= 30

    costN = []
    costP2P = []
    costP2P_TNB = []
    costNEM = []
    reduce_P2P = []
    reduce_NEM = []

    for i in 1:nb_prosumer 
        append!(costN, ResidentialTariff(totalPower[i]))

        append!(costP2P_TNB, ResidentialTariff(totalTNB[i]))
        append!(costP2P, costP2P_TNB[i] + totalP2P[i])

        append!(costNEM, ResidentialTariff(totalNEM[i]))
        costNEM[findall(x->x<0, costNEM)] .= 0
    end

    for i in 1:nb_prosumer
        append!(reduce_P2P, ((costN[i] - costP2P[i]) / costN[i]) * 100)
        append!(reduce_NEM, ((costN[i] - costNEM[i]) / costN[i]) * 100)
    end

    # TNBearn_P2P = sum(Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* (buy_bp'[P2PTrade[1]:P2PTrade[2], :] .- sell_bp'[P2PTrade[1]:P2PTrade[2], :]))
    TNBearn_P2P = sum(Result_P2P_sell[P2PTrade[1]:P2PTrade[2], :] .* (final_buy_price'[P2PTrade[1]:P2PTrade[2]] .- final_sell_price'[P2PTrade[1]:P2PTrade[2]]))
    TNBearn_Normal = sum(Result_Grid_buy[P2PTrade[1]:P2PTrade[2], :] .* tnb_cost[1] * 0.15)
    TNBearn_Selling = sum(Result_Grid_sell[P2PTrade[1]:P2PTrade[2], :] .* (0.35 - tnb_cost[2]))

    TNBearning = ((TNBearn_P2P + TNBearn_Normal + TNBearn_Selling) * 1) + (sum(costP2P_TNB) * 0.15);
    TNBearning_normal = sum(costN) * 0.15

    prosumer_cost = [totalP2P'; costN; costNEM; costP2P; costP2P_TNB; reduce_P2P; reduce_NEM]
    TNBearn = [TNBearn_P2P TNBearn_Normal TNBearn_Selling TNBearning TNBearning_normal]

    return prosumer_cost, TNBearn'
end

function r_2(y_true, y_pred)
    # Calculate the total sum of squares (TSS)
    ss_tot = sum((y_true .- mean(y_true)).^2)
    
    # Calculate the residual sum of squares (RSS)
    ss_res = sum((y_true .- y_pred).^2)
    
    # Calculate R²
    r2 = 1 - (ss_res / ss_tot)
    
    return r2
end

# function get_solutions(model)
#     ### Get the solution of the mdoel

#     solutions = []
#     if JuMP.get_optimizer_attribute(model, "PoolSearchMode") == 2
#         sol_count = MOI.get(model, Gurobi.ModelAttribute("SolCount"))
#         for i in 1:sol_count
#             JuMP.set_optimizer_attribute(model, "SolutionNumber", i)
#             solution = MOI.get(model, Gurobi.ModelAttribute("Xn"))
#         end
#     else

#     end
    
#     return
# end