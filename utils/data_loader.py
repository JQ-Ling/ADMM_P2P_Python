import numpy as np
import pandas as pd

def load_scenario_data(base_dir, bus_sys):
    def csv_matrix(path, header=True):
        df = pd.read_csv(path, header=0 if header else None)
        return df.values

    data = {}
    data["power_consumption"]   = csv_matrix(f"{base_dir}/Power Consumption_{bus_sys}_bus.csv") / 2
    data["solar"]               = csv_matrix(f"{base_dir}/Solar_interpolated_6000.csv")
    data["ptdf"]                = csv_matrix(f"{base_dir}/radial{bus_sys}bus_PTDF.csv", header=False)
    data["branch_limit"]        = pd.read_csv(f"{base_dir}/{bus_sys}_bus_limit_data.csv").iloc[:, 0].values * 1000
    data["buy_bp"]              = csv_matrix(f"{base_dir}/buy_price_{bus_sys}.csv", header=False)
    data["sell_bp"]             = csv_matrix(f"{base_dir}/sell_price_{bus_sys}.csv", header=False)
    data["buy_priority"]        = csv_matrix(f"{base_dir}/buy_priority_{bus_sys}.csv", header=False)
    data["sell_priority"]       = csv_matrix(f"{base_dir}/sell_priority_{bus_sys}.csv", header=False)
    data["nb_bus"], data["nb_branch"] = data["ptdf"].shape[1], data["ptdf"].shape[0]
    return data
