from gurobipy import Model, GRB, quicksum
import numpy as np

def subproblem_grid_operator(Param, P_out, lamda_u, rho_u):
    """
    Full Grid Operator subproblem (matches Julia version)
    """
    h = int(Param['hour'])
    num_user = int(Param['num_user'])

    ptdf = Param['ptdf']
    num_bus = Param['num_bus']
    num_branch = Param['num_branch']
    branch_limit = Param['branch_limit']
    load_demand = Param['load_demamd']
    loc_prosumer = Param['loc_prosumer']
    P2PTrade = Param['P2PTrade']

    m = Model("GridOperator")
    m.Params.OutputFlag = 0

    # === Variables ===
    net_load_hour   = m.addVars(h, num_bus, lb=-GRB.INFINITY)
    P_br            = m.addVars(h, num_branch, lb=-GRB.INFINITY)
    P_out_aux       = m.addVars(4*h, num_user, lb=-GRB.INFINITY)

    # === Constraints ===
    # (1) P2P trade hour zero
    start, end_ = P2PTrade
    for t in range(0, start):
        for u in range(num_user):
            m.addConstr(P_out_aux[2*h + t, u] == 0)
            m.addConstr(P_out_aux[3*h + t, u] == 0)
    for t in range(end_-1, h):
        for u in range(num_user):
            m.addConstr(P_out_aux[2*h + t, u] == 0)
            m.addConstr(P_out_aux[3*h + t, u] == 0)

    # (2) Bus loads (sum of user loads)
    P_load_bus = np.matmul(load_demand, loc_prosumer)

    # (3) net_load_hour composition
    for t in range(h):
        for n in range(num_bus):
            if n == 0:
                m.addConstr(net_load_hour[t, n] == P_load_bus[t, n])
            else:
                m.addConstr(net_load_hour[t, n] == P_load_bus[t, n] +
                            quicksum(P_out_aux[0*h + t, u] - P_out_aux[1*h + t, u]
                                     for u in range(num_user)))

    # (4) PTDF mapping
    for t in range(h):
        for b in range(num_branch):
            m.addConstr(P_br[t, b] ==
                        -quicksum((net_load_hour[t, n] / 0.5) * ptdf[b, n] for n in range(num_bus)))

    # (5) P2P balance (Σbuy = Σsell per hour)
    for t in range(h):
        m.addConstr(quicksum(P_out_aux[2*h + t, u] for u in range(num_user)) ==
                    quicksum(P_out_aux[3*h + t, u] for u in range(num_user)))

    # (6) Branch limits
    for t in range(h):
        for b in range(num_branch):
            m.addConstr(P_br[t, b] <= branch_limit[b])
            m.addConstr(P_br[t, b] >= -branch_limit[b])
    
    # === Objective ===
    lam_it = lamda_u 
    f = quicksum(lam_it[i, u] * P_out_aux[i, u]
                 + 0.5 * rho_u * (P_out_aux[i, u] - P_out[i, u])**2
                 for i in range(4*h) for u in range(num_user))
    m.setObjective(f, GRB.MINIMIZE)
    m.optimize()

    # === Extract ===
    Pout_aux = np.array([[P_out_aux[i, u].X for u in range(num_user)] for i in range(4*h)])
    G_decision = np.concatenate([
        [v.X for v in net_load_hour.values()],
        [v.X for v in P_br.values()],
    ])

    return m.ObjVal, G_decision, Pout_aux, None
