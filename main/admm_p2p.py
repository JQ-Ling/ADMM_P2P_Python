import os, sys
import time
import numpy as np
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
import matplotlib.pyplot as plt

notebook_dir = os.getcwd()  # Gets test folder path
project_dir = os.path.dirname(notebook_dir)  # Gets Project folder path
sys.path.append(project_dir)

from subproblems import *
from utils import *

# Global config
BUS_SYS = 33
DATA_DIR = r"D:\Jacky\Python\ADMM_P2P_Python\data"
RUN_ID = datetime.now().strftime("Run_OneSce_%Y%m%d_%H%M%S")
SCENARIO = 1000 

RHO = 0.6
MAX_ITER = 5000
PRIMAL_TOL, DUAL_TOL = 1e-3, 1e-3
BATTERY_CAP = 2
P2P_TRADE = (16, 38)
SOLAR_SCALER = 1.5

# Worker function for parallel prosumer subproblem solving
def users_worker(i):
    """Run one prosumer subproblem and return index + results."""
    cost, pros_decisions_new, Pout_new, ui_prosumer = subproblem_prosumer(
        params_prosumer, Pout_aux, i, lam, RHO
    )
    return i, cost, pros_decisions_new, Pout_new, ui_prosumer

# Initialize logger
logger = setup_logger(name=RUN_ID, log_file=f"{RUN_ID}.log")
logger.info(f"Initialized single-scenario ADMM run: {RUN_ID}")

data = load_scenario_data(DATA_DIR, BUS_SYS)
hour, num_user = data["power_consumption"].shape
logger.info(f"Loaded {num_user} prosumers × {hour} hours dataset.")

# -----------------------------
# SCENARIO INITIALIZATION
# -----------------------------
solar = data["solar"][SCENARIO - 1, :] * SOLAR_SCALER
net_load = data["power_consumption"].T.copy()
pros_solar = int(np.ceil(num_user / 2)) - 1 # to match with Julia 1-inclusive indexing 
net_load[pros_solar:, :] -= solar[np.newaxis, :]

# == Scenario-specific parameters ==
total_excess = np.sum(np.where(net_load < 0, -net_load, 0), axis=0)
total_deficiency = np.sum(np.where(net_load > 0,  net_load, 0), axis=0)

# === CES battery bounds ===
ub_CES = np.full((hour, num_user), BATTERY_CAP)
lb_CES = np.zeros((hour, num_user))

ub_CESc = np.full((hour, num_user), BATTERY_CAP / 3)  # charging bound
lb_CESc = np.zeros((hour, num_user))

ub_CESd = np.full((hour, num_user), BATTERY_CAP / 3)  # discharging bound
lb_CESd = np.zeros((hour, num_user))

# === Initialize other key parameters ===
beta_tnb = 1
P_CES0 = np.full(num_user, BATTERY_CAP / 2)
efficiency_CES = 1.0

# === Build prosumer parameters ===
params_prosumer = {
    "ub_CES": ub_CES,
    "lb_CES": lb_CES,
    "ub_CESc": ub_CESc,
    "lb_CESc": lb_CESc,
    "ub_CESd": ub_CESd,
    "lb_CESd": lb_CESd,
    "hour": hour,
    "beta_tnb": beta_tnb,
    "CES0": P_CES0,
    "P2PTrade": P2P_TRADE,
    "efficiency_CES": efficiency_CES,
    "buy_priority": data["buy_priority"],
    "sell_priority": data["sell_priority"],
    "load_demamd": net_load.T,  # matches Julia's net_load'
}

# === Build grid parameters ===
params_grid = {
    "hour": hour,
    "num_user": num_user,
    "ptdf": data["ptdf"],
    "num_bus": data["nb_bus"],
    "num_branch": data["nb_branch"],
    "branch_limit": data["branch_limit"],
    "ub_CES": ub_CES,
    "lb_CES": lb_CES,
    "ub_CESc": ub_CESc,
    "lb_CESc": lb_CESc,
    "ub_CESd": ub_CESd,
    "lb_CESd": lb_CESd,
    "buy_priority": data["buy_priority"],
    "sell_priority": data["sell_priority"],
    "efficiency_CES": efficiency_CES,
    "load_demamd": net_load.T,
    "loc_prosumer": np.eye(num_user, data["nb_bus"]),  # same as loc_prosumer[i,i+1] = 1
    "P2PTrade": P2P_TRADE,
}

# === Initialize ADMM variables ===
num_dec = 4
lam = np.zeros((num_dec * hour, num_user))
Pout = np.zeros((num_dec * hour, num_user))
Pout_aux = np.zeros_like(Pout)
pros_decisions = np.zeros((7 * hour, num_user))

lam_all = []
Pout_all = []
Pout_aux_all = []
P_dec_all = []
primal_residuals = [1.0]
dual_residuals = []
primal_errors, dual_errors = [], []
obj_all = []

# -----------------------------
#       ADMM MAIN LOOP
# -----------------------------
iteration = 1
converged = False
start_time = time.time()
while not converged and iteration < MAX_ITER:
    # # === Serial prosumer subproblem solving ===
    # for i in range(num_user):
    #     cost, pros_decisions_new, Pout_new, _ = subproblem_prosumer(
    #         params_prosumer, Pout_aux, i, lam, RHO
    #     )
    #     Pout[:, i] = Pout_new
    #     pros_decisions[:, i] = pros_decisions_new
    
    # === Multi-threaded prosumer subproblem solving ===
    with ThreadPoolExecutor() as ex:
        futures = [ex.submit(users_worker, i) for i in range(num_user)]

        for fut in as_completed(futures):
            i, cost_i, pros_decisions_new, Pout_new, ui_prosumer = fut.result()

            # write into the correct column (same as your serial code)
            Pout[:, i] = Pout_new
            pros_decisions[:, i] = pros_decisions_new

            # If you want to store per-user cost / ui, do it here:
            # cost_vec[i] = cost_i
            # ui_all[:, :, i] = ui_prosumer

    # after all threads finish, snapshot for history
    Pout_all.append(Pout.copy())
    P_dec_all.append(pros_decisions.copy())

    obj_g, grid_decision,Pout_aux, _ = subproblem_grid_operator(
        params_grid, Pout, lam, RHO
    )
    Pout_aux_all.append(Pout_aux.copy())

    lam_last = lam.copy()
    lam = lam + RHO * (Pout_aux - Pout)
    lam_all.append(lam.copy())
    
    p_err, d_err, p_res, d_res = convergence_check(Pout, Pout_aux, lam, lam_last, RHO)
    primal_errors.append(p_err)
    dual_errors.append(d_err)
    primal_residuals.append(p_res)
    dual_residuals.append(d_res)
    obj_val = obj_function(Pout_aux, pros_decisions, data["buy_bp"], data["sell_bp"], beta_tnb=1)
    obj_all.append(obj_val)

    logger.info(f"[Iter {iteration}] p_res={p_res:.3e}, d_res={d_res:.3e}, obj={obj_val}")
    if p_res < PRIMAL_TOL and d_res < DUAL_TOL:
        converged = True
    iteration += 1

exec_time = time.time() - start_time
logger.info(f"[DONE] Scenario {SCENARIO} completed | {iteration} iters | {exec_time:.2f}s")

Pout_all = np.stack(Pout_all, axis=2)
lam_all = np.stack(lam_all, axis=2)
Pout_aux_all = np.stack(Pout_aux_all, axis=2)
P_dec_all = np.stack(P_dec_all, axis=2)

# -----------------------------
#     CONVERGENCE PLOTTING 
# -----------------------------
plt.figure(figsize=(6,4))
plt.semilogy(primal_residuals, label="Primal Residual")
plt.semilogy(dual_residuals, label="Dual Residual")
plt.title(f"ADMM Convergence — Scenario {SCENARIO}")
plt.xlabel("Iteration")
plt.ylabel("Residual (log scale)")
plt.legend()
plt.grid(True)

figure_path = os.path.join(project_dir, 'output','logs',f'{RUN_ID}_conv_res.png')
plt.savefig(figure_path)

plt.show()

# -----------------------------
#       RESULTS SAVING 
# -----------------------------
prt_comp = [True, project_dir, RUN_ID]

prosumer_cost, TNBearn = profit_cal(
    pros_decisions, Pout_aux, data['buy_priority'], data['sell_priority'],
    total_excess, net_load,
    data["buy_bp"], data["sell_bp"], [0.57, 0.15],
    data["power_consumption"], SOLAR_SCALER, BATTERY_CAP, P2P_TRADE, print_result=prt_comp
)

oneSave(
    Pout_aux, lam, pros_decisions, grid_decision,
    exec_time, iteration, primal_errors, dual_errors,
    primal_residuals, dual_residuals, obj_all,
    data["buy_priority"], data["sell_priority"], net_load.T, params_grid,
    path="OneScenario", run_id=RUN_ID
)

logger.info(f"[SAVE] Scenario {SCENARIO} results saved successfully.")