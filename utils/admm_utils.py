# utils/admm_utils.py
import numpy as np
import logging
import os

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def obj_function(Pout_aux, P_decision, buy_bp, sell_bp, beta_tnb):
    h = Pout_aux.shape[0] // 4
    P_c = Pout_aux[0*h:1*h, :]
    P_d = Pout_aux[1*h:2*h, :]
    P_buy = Pout_aux[2*h:3*h, :]
    P_sell = Pout_aux[3*h:4*h, :]

    Pg_buy = P_decision[0*h:1*h, :]
    Pg_sell = P_decision[1*h:2*h, :]

    f1 = np.sum(P_buy * buy_bp.T + P_sell * sell_bp.T)
    f2 = np.sum(beta_tnb * (Pg_buy + Pg_sell))
    f3 = np.sum(0.005 * (P_c + P_d))
    return f1 + f2 + f3

def convergence_check(Pout, Pout_aux, lam, lam_last, rho):
    p_err = np.sum(np.abs(Pout - Pout_aux))
    d_err = np.sum(np.abs(rho * (lam - lam_last)))
    p_res = np.sqrt(np.sum((Pout - Pout_aux) ** 2))
    d_res = np.sqrt(np.sum((rho * (lam - lam_last)) ** 2))
    return p_err, d_err, p_res, d_res

def setup_logger(name=None, log_file=None):
    logs_dir = os.path.join(PROJECT_DIR, 'output', 'logs')
    logger = logging.getLogger(name or 'global_logger')
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    log_file = os.path.join(logs_dir, log_file or 'general.log')
    file_handler = logging.FileHandler(log_file)
    file_handler.setFormatter(formatter)

    if not logger.handlers:
        logger.addHandler(console_handler)
        logger.addHandler(file_handler)

    return logger