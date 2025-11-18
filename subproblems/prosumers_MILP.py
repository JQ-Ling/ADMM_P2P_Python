# subproblems/prosumer.py
from pyexpat import model
from gurobipy import Model, GRB, quicksum
import numpy as np


def subproblem_prosumer_MILP(Param, Pout_aux, user_id, lamda_u, rho_u):
    """
    Full Prosumer subproblem
    """
    h = int(Param['hour'])
    u = user_id
    
    # === Extract Params ===
    ub_CES, lb_CES = Param['ub_CES'], Param['lb_CES']
    ub_CESc, lb_CESc = Param['ub_CESc'], Param['lb_CESc']
    ub_CESd, lb_CESd = Param['ub_CESd'], Param['lb_CESd']
    beta_tnb = Param['beta_tnb']
    eta = Param['efficiency_CES']
    P_CES0 = Param['CES0'][u]
    P2PTrade = Param['P2PTrade']
    P_load = Param['load_demamd'][:, u]
    PI_buy = Param['buy_priority'][u, :]
    PI_sell = Param['sell_priority'][u, :]

    z_u = Pout_aux[:, u]
    lam_u = lamda_u[:, u]

    m = Model(f"Prosumer_{u}")
    m.Params.OutputFlag = 0

    # === Variables ===
    nload   = m.addVars(h, lb=-GRB.INFINITY,    name="nload")
    P_buy   = m.addVars(h, lb=0,                name="P_buy")
    P_sell  = m.addVars(h, lb=0,                name="P_sell")
    Pg_buy  = m.addVars(h, lb=0,                name="Pg_buy")
    Pg_sell = m.addVars(h, lb=0,                name="Pg_sell")
    P_CES   = m.addVars(h, lb=0,                name="P_CES")
    P_c     = m.addVars(h, lb=0,                name="P_c")
    P_d     = m.addVars(h, lb=0,                name="P_d")
    b_trade = m.addVars(h, vtype='B',           name='b_trade')

    # === Start Values ===
    m.setAttr("Start", P_c, z_u[0*h : 1*h])
    m.setAttr("Start", P_d, z_u[1*h : 2*h])
    m.setAttr("Start", P_buy, z_u[2*h : 3*h])
    m.setAttr("Start", P_sell, z_u[3*h : 4*h])

    # === Binary load indicator ===
    # 1 = NL, 0 = SE
    B_load = (P_load > 0).astype(int)

    # === Bounds ===
    for t in range(h):
        m.addConstr(P_CES[t] >= lb_CES[t, u])
        m.addConstr(P_CES[t] <= ub_CES[t, u])
        m.addConstr(P_c[t]   >= lb_CESc[t, u])
        m.addConstr(P_c[t]   <= ub_CESc[t, u])
        m.addConstr(P_d[t]   >= lb_CESd[t, u])
        m.addConstr(P_d[t]   <= ub_CESd[t, u])

    # === P2P Trade zeroes outside window ===
    # Alternative simpler version assuming P2PTrade is 0-based exclusive
    start, end_ = P2PTrade 
    for t in range(0, start): # 0 ~ 15 -> 1 ~ 16
        m.addConstr(P_buy[t] == 0) 
        m.addConstr(P_sell[t] == 0) 
    for t in range(end_ - 1, h):  # 37 ~ 47 -> 38 ~ 48
        m.addConstr(P_buy[t] == 0) 
        m.addConstr(P_sell[t] == 0)

    # === Net Load Equations ===
    for t in range(h):
        m.addConstr(P_load[t] + P_c[t] - P_d[t] - (Pg_buy[t] + P_buy[t]) + Pg_sell[t] + P_sell[t] == 0)

    # === MILP Trade ===
    M = 1000000
    for t in range(h):
        m.addConstr(Pg_buy[t] <= M * b_trade)
        m.addConstr(Pg_buy[t] >= 0 * b_trade)
        m.addConstr(P_buy[t] <= M * b_trade)
        m.addConstr(P_buy[t] >= 0 * b_trade)
        m.addConstr(Pg_sell[t] <= M * (1 - b_trade))
        m.addConstr(Pg_sell[t] >= 0 * (1 - b_trade))
        m.addConstr(P_sell[t] <= M * (1 - b_trade))
        m.addConstr(P_sell[t] >= 0 * (1 - b_trade))

    # === Extended Linearization (ExLP) ===
    for t in range(h - 1):
        m.addConstr(P_c[t+1] <= (ub_CES[t, u] - P_CES[t]) / eta)
        m.addConstr(P_d[t+1] <= (P_CES[t] - lb_CES[t, u]) * eta)
        m.addConstr(P_d[t] <= ub_CESd[t, u] - (ub_CESd[t, u] / ub_CESc[t, u]) * P_c[t])

    m.addConstr(P_c[0] <= (ub_CES[0, u] - P_CES0) / eta)
    m.addConstr(P_d[0] <= (P_CES0 - lb_CES[0, u]) * eta)

    # === SOC dynamics (looped) ===
    m.addConstr(P_CES[0] == P_CES0)
    m.addConstr(P_CES[h-1] == P_CES[0])
    for t in range(h-1):
        m.addConstr(P_CES[t+1] == P_CES[t] + eta*P_c[t] - (P_d[t]/eta))
    m.addConstr(P_CES[0] == P_CES[h-1] + eta*P_c[h-1] - (P_d[h-1]/eta))

    # === Objective ===
    f1 = quicksum(P_buy[t] * PI_buy[t] + P_sell[t] * PI_sell[t] for t in range(h))
    f2 = quicksum(beta_tnb * (Pg_buy[t] + Pg_sell[t]) for t in range(h))
    f3 = quicksum(0.005 * (P_c[t] + P_d[t]) for t in range(h))

    Sx = [P_c[t] for t in range(h)] + [P_d[t] for t in range(h)] + \
         [P_buy[t] for t in range(h)] + [P_sell[t] for t in range(h)]

    f4 = quicksum(-lam_u[i] * Sx[i] for i in range(4*h)) + \
         quicksum(0.5 * rho_u * (Sx[i] - z_u[i])**2 for i in range(4*h))

    m.setObjective(f1 + f2 + f3 + f4, GRB.MINIMIZE)
    m.optimize()

    # === Extract ===
    Pout = np.concatenate([
        [v.X for v in P_c.values()],
        [v.X for v in P_d.values()],
        [v.X for v in P_buy.values()],
        [v.X for v in P_sell.values()],
    ])
    P_decision = np.concatenate([
        [v.X for v in Pg_buy.values()],
        [v.X for v in Pg_sell.values()],
        [v.X for v in P_CES.values()],
        [v.X for v in P_c.values()],
        [v.X for v in P_d.values()],
        [v.X for v in P_buy.values()],
        [v.X for v in P_sell.values()],
    ])


    return m.ObjVal, P_decision, Pout, None