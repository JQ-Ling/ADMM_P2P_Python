# utils/data_saver.py
import os
import numpy as np
import pandas as pd
from datetime import datetime

def ensure_dir(path, logger=None):
    """Create directory if it doesn’t exist."""
    if not os.path.exists(path):
        os.makedirs(path)
        if logger:
            logger.debug(f"[DIR] Created directory: {path}")
    else:
        if logger:
            logger.debug(f"[DIR] Directory already exists: {path}")

# ===========================================================
# 🧱 1. Save single-scenario checkpoint
# ===========================================================
def save_checkpoint(sce_idx, primal, dual, P_decision, loc_prosumer, obj, path, logger=None):
    """
    Save one scenario’s result to NPZ as checkpoint.
    File: checkpoints/scenario_XXXX.npz
    """
    base = f"D:/Jacky/Python/ADMM_P2P_Python/output/runs/{path}/checkpoints"
    ensure_dir(base, logger)
    file_path = os.path.join(base, f"scenario_{sce_idx:04d}.npz")

    try:
        np.savez(file_path,
                 primal=primal,
                 dual=dual,
                 P_decision=P_decision,
                 loc_prosumer=loc_prosumer,
                 obj=obj)

        msg = f"[Checkpoint] Scenario {sce_idx} saved → {file_path}"
        logger.info(msg) if logger else print(msg)
    except Exception as e:
        msg = f"[ERROR] Failed to save checkpoint for scenario {sce_idx}: {e}"
        logger.exception(msg) if logger else print(msg)

# ===========================================================
# 🧱 2. Merge multiple checkpoints
# ===========================================================
def merge_checkpoints(path, remove_old=False, logger=None):
    """
    Merge all .npz files under 'checkpoints/' into a single 'merged/run_data.npz'.
    Optionally delete old checkpoint files after merging.
    """
    base = f"D:/Jacky/Python/ADMM_P2P_Python/output/runs/{path}"
    check_dir = os.path.join(base, "checkpoints")
    merged_dir = os.path.join(base, "merged")
    ensure_dir(merged_dir, logger)

    files = sorted([f for f in os.listdir(check_dir) if f.endswith(".npz")])
    if not files:
        msg = "[Merge] No checkpoint files found."
        logger.warning(msg) if logger else print(msg)
        return

    all_primal, all_dual, all_Pdec, all_loc, all_obj = [], [], [], [], []

    for f in files:
        try:
            data = np.load(os.path.join(check_dir, f))
            all_primal.append(data["primal"])
            all_dual.append(data["dual"])
            all_Pdec.append(data["P_decision"])
            all_loc.append(data["loc_prosumer"])
            all_obj.append(data["obj"])
        except Exception as e:
            msg = f"[WARNING] Skipped corrupted file {f}: {e}"
            logger.warning(msg) if logger else print(msg)
            continue

    if not all_primal:
        msg = "[Merge] No valid data found to merge."
        logger.warning(msg) if logger else print(msg)
        return

    merged = {
        "primal": np.stack(all_primal, axis=0),
        "dual": np.stack(all_dual, axis=0),
        "P_decision": np.stack(all_Pdec, axis=0),
        "loc_prosumer": np.stack(all_loc, axis=0),
        "obj": np.stack(all_obj, axis=0)
    }

    save_path = os.path.join(merged_dir, f"run_data_{len(files)}.npz")
    np.savez(save_path, **merged)

    msg = f"[Merge] Consolidated {len(files)} scenarios → {save_path}"
    logger.info(msg) if logger else print(msg)

    if remove_old:
        for f in files:
            os.remove(os.path.join(check_dir, f))
        msg = f"[Cleanup] Deleted {len(files)} checkpoint files."
        logger.info(msg) if logger else print(msg)

# ===========================================================
# 🧱 3. (Optional) Auto-cleanup or resume
# ===========================================================
def get_last_saved_index(path, logger=None):
    """Return the highest scenario index saved so far."""
    check_dir = f"D:/Jacky/Data Output/ADMM_P2P/Database/{path}/checkpoints"
    if not os.path.exists(check_dir):
        msg = f"[Resume] No checkpoint directory found at {check_dir}"
        logger.info(msg) if logger else print(msg)
        return 0

    files = sorted([f for f in os.listdir(check_dir) if f.startswith("scenario_")])
    if not files:
        msg = "[Resume] No checkpoint files found."
        logger.info(msg) if logger else print(msg)
        return 0

    last_idx = int(files[-1].split("_")[1].split(".")[0])
    msg = f"[Resume] Last saved scenario index: {last_idx}"
    logger.info(msg) if logger else print(msg)
    return last_idx

# ===========================================================
# 🧱 4. Save complete single-scenario outputs (oneSave)
# ===========================================================

def oneSave(Pout_aux, lam, Prosumer_decision, Grid_decision,
            execution_time, iteration_num, primal_error, dual_error,
            primal_residual, dual_residual, obj_all,
            buy_priority, sell_priority, net_load, params_grid,
            path="OneScenario", run_id=None, logger=None):
    """
    Save all results for one scenario run — similar to Julia's oneSave().
    Creates a timestamped folder and saves all major arrays as CSV + NPZ.
    """

    # Timestamped folder for organization
    base_dir = f"D:/Jacky/Python/ADMM_P2P_Python/output/{path}"
    save_path = os.path.join(base_dir, run_id)
    ensure_dir(save_path, logger)

    # --- Helper: CSV saving ---
    def save_csv(data, name):
        file_path = os.path.join(save_path, f"{name}.csv")
        try:
            df = pd.DataFrame(data)
            df.to_csv(file_path, index=False)
            if logger:
                logger.info(f"[oneSave] Saved {name}.csv")
        except Exception as e:
            if logger:
                logger.error(f"[oneSave] Failed to save {name}.csv: {e}")
            else:
                print(f"[oneSave] Failed to save {name}.csv: {e}")

    # --- Save scalar / vector results ---
    save_csv([execution_time], "execution_time")
    save_csv([iteration_num], "iteration_num")
    save_csv(primal_error, "primal_error")
    save_csv(dual_error, "dual_error")
    save_csv(primal_residual, "primal_residual")
    save_csv(dual_residual, "dual_residual")
    save_csv(obj_all, "objective_values")

    # --- Save major matrices ---
    save_csv(Pout_aux, "Pout_last")
    save_csv(lam, "dual_last")
    save_csv(Prosumer_decision, "P_decision")
    save_csv(Grid_decision, "G_decision")
    save_csv(buy_priority, "buy_priority")
    save_csv(sell_priority, "sell_priority")
    save_csv(net_load, "net_load")

    # --- Save compressed numpy arrays (binary) ---
    np.savez(os.path.join(save_path, "arrays.npz"),
             Pout_aux=Pout_aux,
             lam=lam,
             Prosumer_decision=Prosumer_decision,
             Grid_decision=Grid_decision,
             primal_error=np.array(primal_error),
             dual_error=np.array(dual_error),
             obj_all=np.array(obj_all))

    # --- Save grid metadata for reference ---
    np.savez(os.path.join(save_path, "params_grid.npz"), **params_grid)

    msg = f"[oneSave] Scenario results saved successfully at {save_path}"
    if logger:
        logger.info(msg)
    else:
        print(msg)
