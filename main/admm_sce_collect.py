# main/admm_sce_collect.py
import os
import time
import numpy as np
from datetime import datetime
from subproblems import subproblem_grid_operator, subproblem_prosumer
from utils import *

# ============================================================
# CONFIGURATION
# ============================================================
BUS_SYS = 33
DATA_DIR = r"D:\Jacky\Python\ADMM_P2P_Python\data"
RUN_ID = "Run_test_1"

# Initialize logger
logger = setup_logger(name=RUN_ID, log_file=f"{RUN_ID}.log")

RHO = 0.6
MAX_ITER = 5000
AI_INJECT_ITER = 12
PRIMAL_TOL, DUAL_TOL = 1e-3, 1e-3
BATTERY_CAP = 2
P2P_TRADE = (16, 38)
SCENARIO_START, SCENARIO_END = 1000, 1020  # example range

logger.info(f"Starting new ADMM run: {RUN_ID}")
logger.info(f"System: {BUS_SYS}-bus | Range: {SCENARIO_START}-{SCENARIO_END}")

# ============================================================
# LOAD DATA
# ============================================================
data = load_scenario_data(DATA_DIR, BUS_SYS)
hour, num_user = data["power_consumption"].shape
logger.info(f"Loaded dataset: {num_user} prosumers × {hour} hours")

# ============================================================
# RESUME HANDLING
# ============================================================
last_saved = get_last_saved_index(RUN_ID, logger=logger)
if last_saved > 0:
    logger.info(f"Resuming from scenario {last_saved + 1} (last saved {last_saved})")
else:
    logger.info(f"Fresh run: {RUN_ID}")

# ============================================================
# MAIN SCENARIO LOOP
# ============================================================
for sce in range(max(SCENARIO_START, last_saved + 1), SCENARIO_END + 1):
    start_time = time.time()
    logger.info(f"===== Running Scenario {sce} =====")

    try:
        # -----------------------------
        # SCENARIO INITIALIZATION
        # -----------------------------
        solar = data["solar"][sce, :] * 1.5
        net_load = data["power_consumption"].T.copy()
        pros_solar = int(np.ceil(num_user / 2))
        net_load[pros_solar:, :] -= solar[:, np.newaxis]

        params_prosumer = {
            "hour": hour,
            "beta_tnb": 1,
            "battery_cap": BATTERY_CAP,
            "CES0": np.ones(num_user) * (BATTERY_CAP / 2),
            "buy_priority": data["buy_priority"],
            "sell_priority": data["sell_priority"],
            "load_demamd": net_load.T,
            "efficiency_CES": 1,
            "P2PTrade": P2P_TRADE,
        }

        params_grid = {
            "hour": hour,
            "num_user": num_user,
            "ptdf": data["ptdf"],
            "num_bus": data["nb_bus"],
            "num_branch": data["nb_branch"],
            "branch_limit": data["branch_limit"],
            "efficiency_CES": 1,
            "buy_priority": data["buy_priority"],
            "sell_priority": data["sell_priority"],
            "load_demamd": net_load.T,
            "P2PTrade": P2P_TRADE,
        }

        # -----------------------------
        # ADMM INITIALIZATION
        # -----------------------------
        num_dec = 4
        lam = np.zeros((num_dec * hour, num_user, MAX_ITER))
        Pout = np.zeros((num_dec * hour, num_user))
        Pout_aux = np.zeros_like(Pout)

        primal_residuals = [1.0]
        dual_residuals = []
        primal_errors, dual_errors = [], []
        obj_all = []
        iteration = 2
        converged = False

        # -----------------------------
        # ADMM LOOP
        # -----------------------------
        while not converged and iteration < MAX_ITER:
            Pout_new, cost, pros_decisions, _ = subproblem_prosumer(
                params_prosumer, Pout_aux, 1, lam, iteration, RHO
            )
            Pout = Pout_new

            obj_g, Pout_aux_new, grid_decision, _ = subproblem_grid_operator(
                params_grid, Pout, lam, iteration, RHO
            )
            Pout_aux = Pout_aux_new

            lam[:, :, iteration] = lam[:, :, iteration - 1] + RHO * (Pout_aux - Pout)

            p_err, d_err, p_res, d_res = convergence_check(Pout, Pout_aux, lam, RHO, iteration)
            primal_errors.append(p_err)
            dual_errors.append(d_err)
            primal_residuals.append(p_res)
            dual_residuals.append(d_res)
            obj_val = obj_function(Pout_aux, pros_decisions, data["buy_bp"], data["sell_bp"], beta_tnb=1)
            obj_all.append(obj_val)

            logger.info(f"Iter {iteration}: p_res={p_res:.3e}, d_res={d_res:.3e}")

            if p_res < PRIMAL_TOL and d_res < DUAL_TOL:
                converged = True
            iteration += 1

        exec_time = time.time() - start_time
        logger.info(f"Scenario {sce} completed | {iteration} iters | {exec_time:.2f}s")

        # -----------------------------
        # POSTPROCESSING
        # -----------------------------
        prosumer_cost, TNBearn = profit_cal(
            pros_decisions, Pout_aux, np.zeros(hour), net_load,
            data["buy_bp"], data["sell_bp"], [0.57, 0.15],
            data["power_consumption"], 1.5, BATTERY_CAP, P2P_TRADE
        )

        # Save per-scenario checkpoint
        save_checkpoint(
            sce, Pout_aux, lam[:, :, iteration - 1], pros_decisions,
            net_load.T, obj_all, RUN_ID, logger=logger
        )

        # Merge every 10 scenarios
        if sce % 10 == 0:
            merge_checkpoints(RUN_ID, remove_old=True, logger=logger)

        logger.info(f"[SAVE] Scenario {sce} checkpoint written successfully.")

    except Exception as e:
        logger.exception(f"[ERROR] Scenario {sce} failed due to: {e}")
        continue

logger.info(f"=== Run Complete: {RUN_ID} ===")
