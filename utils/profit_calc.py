import numpy as np
import pandas as pd
import os

ROW_FMT = (
    "{:>12}"       # Participants
    "{:>12}"       # Net Load
    "{:>12}"       # Charge
    "{:>12}"       # Discharge
    "{:>18}"       # Net Load (Bat)
    "{:>16}"       # Buy P2P (prio)
    "{:>18}"       # Sell P2P (prio)
    "{:>12}"       # Buy TNB
    "{:>12}"       # Sell TNB"
)

ROW_FMT_2 = (
    "{:<15}"   # Participant name
    "{:>10}"   # Power
    "{:>10}"   # Net Load
    "{:>14}"   # Normal Cost
    "{:>12}"   # NEM Cost
    "{:>12}"   # P2P Cost
    "  {:0}  " # | separator, centered
    "{:>12}"   # P2P Margin
    "{:>14}"   # TNB (non-P2P)
)




# ============================================================
# 1. Priority Conversion
# ============================================================
def prio_conversion(Prio, Excess, netload, BS):
    """
    Convert continuous priority to integer ranking (buying/selling priority)
    Equivalent to Julia's PrioConversion
    """
    nb_prosumer = Prio.shape[0]
    hour = Prio.shape[1]

    intPrio = Prio.T.copy()
    sortPrio = np.sort(intPrio, axis=1)

    for i in range(hour):
        rank = 1
        for j in range(nb_prosumer):
            for k in range(nb_prosumer):
                if Excess[i] > 0:
                    # Buying priority
                    if BS == 0:
                        if netload[i, k] > 0:
                            if sortPrio[i, j] == intPrio[i, k]:
                                intPrio[i, k] = rank
                                rank += 1
                        else:
                            intPrio[i, k] = 0
                    # Selling priority
                    elif BS == 1:
                        if netload[i, k] < 0:
                            if sortPrio[i, j] == intPrio[i, k]:
                                intPrio[i, k] = rank
                                rank += 1
                        else:
                            intPrio[i, k] = 0
                else:
                    intPrio[i, k] = 0
    return intPrio


# ============================================================
# 2. Tariff Calculations
# ============================================================
def commercial_tariff(Power):
    price = [0.435, 0.509]
    rng = 200
    if Power > rng:
        return rng * price[0] + (Power - rng) * price[1]
    else:
        return Power * price[0]


def industrial_tariff(Power):
    price = [0.380, 0.441]
    rng = 200
    if Power > rng:
        return rng * price[0] + (Power - rng) * price[1]
    else:
        return Power * price[0]


def residential_tariff(Power):
    # Simplified: constant tariff (Julia version uses 0.57 × ones)
    TarrifPrice = np.ones(5) * 0.57
    TarrifRange = [200, 100, 300, 300]
    i = 1

    while Power - sum(TarrifRange[:i]) > 0:
        i += 1
        if i == 5:
            break

    total_cost = sum(TarrifPrice[:i-1] * TarrifRange[:i-1]) + \
                 (Power - sum(TarrifRange[:i-1])) * TarrifPrice[i-1]
    return total_cost


# ============================================================
# 3. Profit and Result Calculations
# ============================================================
def profit_cal(Prosumer_decision, Pout_aux,
               buy_priority, sell_priority,
               total_excess, net_load,
               buy_bp, sell_bp, tnb_cost, power_consumption,
               SolarScaler, BatteryCap, P2PTrade,
               print_result=None):
    """
    Calculation of TNB profit and prosumer cost.
    (Exclude CES services for each parties)

    Returns
    -------
    prosumer_cost : (7, N) array
        [totalP2P, costN, costNEM, costP2P, costP2P_TNB, reduce_P2P%, reduce_NEM%]
    TNBearn : (5,) array
        [TNBearn_P2P, TNBearn_Normal, TNBearn_Selling, TNBearning, TNBearning_normal]
    """

    hour, nb_prosumer = power_consumption.shape

    # --- Slice decision variables (matching Julia indexing but 0-based) ---
    Result_Grid_buy  = Prosumer_decision[0*hour:1*hour, :]
    Result_Grid_sell = Prosumer_decision[1*hour:2*hour, :]
    Result_bat_lv    = Prosumer_decision[2*hour:3*hour, :]  # not used further but kept

    Result_Charge    = Pout_aux[0*hour:1*hour, :]
    Result_Discharge = Pout_aux[1*hour:2*hour, :]
    Result_P2P_buy   = Pout_aux[2*hour:3*hour, :]
    Result_P2P_sell  = Pout_aux[3*hour:4*hour, :]

    # --- Prices and net load with battery ---
    # (assumes buy_bp, sell_bp: (hour, nb_prosumer) or compatible)
    final_buy_price  = np.sum(buy_bp, axis=0) / nb_prosumer   # shape (hour,)
    final_sell_price = np.sum(sell_bp, axis=0) / nb_prosumer  # shape (hour,)

    # net_load is assumed (nb_prosumer, hour) like in Julia
    NetLoad = net_load.T + Result_Charge - Result_Discharge   # (hour, nb_prosumer)

    # --- Priority matrices ---
    nbBuyPrio  = prio_conversion(buy_priority,  total_excess, NetLoad, 0)
    nbSellPrio = prio_conversion(sell_priority, total_excess, NetLoad, 1)

    # --- Aggregate energy quantities ---
    totalPower = np.sum(power_consumption, axis=0)     # (N,) total consumption
    totalNEM   = np.sum(net_load.T, axis=0)            # (N,)

    # --- P2P trade hour ---
    # Trade hour: 17 ~ 37 (1 indexing)
    # if wanna call non trading hour: 0 ~ 15, 37 ~ 47, [0:16; 37:48] for Python
    # if wanna call trading hour: 16 ~ 36, [16:37] for Python
    P2P_start, P2P_end = P2PTrade[0], P2PTrade[1] - 1

    # Broadcast prices to (time, prosumer)
    fb = final_buy_price[:, np.newaxis]
    fs = final_sell_price[:, np.newaxis]

    totalP2P = np.sum(
        (Result_P2P_buy[P2P_start:P2P_end, :]  * fb[P2P_start:P2P_end, :]) -
        (Result_P2P_sell[P2P_start:P2P_end, :] * fs[P2P_start:P2P_end, :]) +
        (Result_Grid_buy[P2P_start:P2P_end, :] * tnb_cost[0]) -
        (Result_Grid_sell[P2P_start:P2P_end, :] * tnb_cost[1]),
        axis=0,
    )

    totalTNB = np.zeros(nb_prosumer)
    for t in range(hour):
        if t < P2P_start or t >= P2P_end:
            totalTNB += Result_Grid_buy[t, :]

    # --- Tariff-based cost calculations for each prosumer ---
    costN, costP2P, costP2P_TNB, costNEM = [], [], [], []
    for i in range(nb_prosumer):
        cn   = residential_tariff(totalPower[i])     # Normal tariff
        cpt  = residential_tariff(totalTNB[i])       # TNB part under P2P
        cp   = cpt + totalP2P[i]                     # P2P + grid at non-P2P hours
        cnem = residential_tariff(totalNEM[i])       # NEM cost
        if cnem < 0:
            cnem = 0.0

        costN.append(cn)
        costP2P_TNB.append(cpt)
        costP2P.append(cp)
        costNEM.append(cnem)

    costN        = np.array(costN)
    costP2P      = np.array(costP2P)
    costP2P_TNB  = np.array(costP2P_TNB)
    costNEM      = np.array(costNEM)

    reduce_P2P = ((costN - costP2P) / costN) * 100.0
    reduce_NEM = ((costN - costNEM) / costN) * 100.0

    # --- TNB earnings ---
    TNBearn_P2P = np.sum(
        Result_P2P_sell[P2P_start:P2P_end, :] *
        (fb[P2P_start:P2P_end, :] - fs[P2P_start:P2P_end, :])
    )
    TNBearn_Normal   = np.sum(Result_Grid_buy[P2P_start:P2P_end, :]  * tnb_cost[0] * 0.15)
    TNBearn_Selling  = np.sum(Result_Grid_sell[P2P_start:P2P_end, :] * (0.35 - tnb_cost[1]))

    TNBearning        = (TNBearn_P2P + TNBearn_Normal + TNBearn_Selling) + np.sum(costP2P_TNB) * 0.15
    TNBearning_normal = np.sum(costN) * 0.15

    prosumer_cost = np.vstack([
        totalP2P,
        costN,
        costNEM,
        costP2P,
        costP2P_TNB,
        reduce_P2P,
        reduce_NEM,
    ])

    TNBearn = np.array([
        TNBearn_P2P,
        TNBearn_Normal,
        TNBearn_Selling,
        TNBearning,
        TNBearning_normal,
    ])

    # =====================================================================
    # PRINTING SECTION (translation of Julia's ResultPrint)
    # =====================================================================
    prt_ = False if print_result == None else print_result[0]
    out_file = os.path.join(print_result[1], 'output', 'logs', f'{print_result[2]}_profit.txt') 
    if prt_:
        with open(out_file, "w") as f:
            print("#######################################", file=f)
            print("Printing Result", file=f)
            print("#######################################", file=f)

            # ----- (1) Priority table -----
            print("Priority", file=f)
            print("------------------------------------------------------", file=f)
            for i in range(0, hour):
            # for i in range(P2P_start, P2P_end):

                print(f"\nTime Step {i+1}", file=f)
                print(ROW_FMT.format(
                    "Participant", "NetLoad", "Charge", "Discharge", "NetLoad(Bat)",
                    "BuyP2P(prio)", "SellP2P(prio)", "BuyTNB", "SellTNB"
                ), file=f)

                for j in range(nb_prosumer):
                    nl   = net_load[j, i]
                    ch   = Result_Charge[i, j]
                    dis  = Result_Discharge[i, j]
                    nl_b = NetLoad[i, j]
                    b_p2p = Result_P2P_buy[i, j]
                    s_p2p = Result_P2P_sell[i, j]
                    bprio = nbBuyPrio[i, j]
                    sprio = nbSellPrio[i, j]
                    b_tnb = Result_Grid_buy[i, j]
                    s_tnb = Result_Grid_sell[i, j]

                    print(ROW_FMT.format(
                        f"Participant {j+1}",
                        f"{nl:.2f}",
                        f"{ch:.2f}",
                        f"{dis:.2f}",
                        f"{nl_b:.2f}",
                        f"{b_p2p:.2f} ({bprio:.0f})",
                        f"{s_p2p:.2f} ({sprio:.0f})",
                        f"{b_tnb:.2f}",
                        f"{s_tnb:.2f}",
                    ), file=f)
                print("-----------------------------------------------------------------------------", file=f)

            # ----- (2) Pricing per prosumer -----
            print("\nPricing for each prosumer (Day)", file=f)
            print("------------------------------------------------------", file=f)
            print(ROW_FMT_2.format(
                "Participant", "Power", "NetLoad", "NormalCost","NEMCost", 
                "P2PCost", "|", "From P2P", "TNB(non-P2P)"
                ), file=f)

            for i in range(nb_prosumer):
                print(ROW_FMT.format(
                    f"Participant {i+1}",
                    f"{totalPower[i]:.2f}",
                    f"{totalNEM[i]:.2f}",
                    f"{costN[i]:.2f}",
                    f"{costNEM[i]:.2f}",
                    f"{costP2P[i]:.2f}",
                    "|",                         # <-- KEEP THE |
                    f"{totalP2P[i]:.2f}",
                    f"{costP2P_TNB[i]:.2f}"
                ), file=f)

            # ----- (3) Average profit / costing -----
            print("\n------------------------------------------------------", file=f)
            print("Average Profit / Costing", file=f)
            print("------------------------------------------------------", file=f)
            print("Participants   P2P Cost   NEM Cost   Normal Cost   "
                "Reduction P2P (%)   Reduction NEM (%)", file=f)

            for i in range(nb_prosumer):
                print(
                    f"Participant {i+1:2d}  "
                    f"{costP2P[i]:9.2f}  "
                    f"{costNEM[i]:9.2f}  "
                    f"{costN[i]:11.2f}  "
                    f"{reduce_P2P[i]:17.2f}  "
                    f"{reduce_NEM[i]:17.2f}"
                , file=f)

            # ----- (4) TNB profits -----
            print("\n------------------------------------------------------", file=f)
            print("Profit for TNB (day)", file=f)
            print("------------------------------------------------------", file=f)

            print("With P2P", file=f)
            print("-----------------------------", file=f)
            print(f"P2P                    : {TNBearn_P2P:.2f}", file=f)
            print(f"Normal (Trading Hour)  : {TNBearn_Normal:.2f}", file=f)
            print(f"Normal (Non Trading Hr): {np.sum(costP2P_TNB) * 0.15:.2f}", file=f)
            print(f"Sell off purchased elec: {TNBearn_Selling:.2f}\n", file=f)

            print("Normal", file=f)
            print("-----------------------------", file=f)
            print(f"Normal tariff cost     : {TNBearning_normal:.2f}\n", file=f)

            print("NEM", file=f)
            print("-----------------------------", file=f)
            print(f"Normal tariff cost     : {np.sum(costNEM) * 0.15:.2f}\n", file=f)

            print(f"Total Profit with P2P  : {TNBearning:.2f}", file=f)
            print(f"Total Profit with NEM  : {np.sum(costNEM) * 0.15:.2f}", file=f)
            print(f"Total Profit Normal    : {TNBearning_normal:.2f}\n", file=f)

            print(f"Solar Installed = {SolarScaler} kWp", file=f)
            print(f"Battery Capacity = {BatteryCap} kWh\n", file=f)

    # end of printing section
    return prosumer_cost, TNBearn
