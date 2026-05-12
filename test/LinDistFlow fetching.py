import pandas as pd
import numpy as np
import urllib.request
import re

def generate_118zh_excel_pu():
    # ==========================================
    # SET YOUR BASE VALUES HERE
    # ==========================================
    v_BASE_KV = 11.0    # Substation Voltage in kV
    s_BASE_MVA = 10.0   # System Base Power in MVA

    # Calculate z_base
    z_BASE = (v_BASE_KV ** 2) / s_BASE_MVA
    print(f"Calculated z_base: {z_BASE} Ohms")
    # ==========================================

    print("Fetching IEEE 118-bus (case118zh) distribution data from MATPOWER...")
    url = "https://raw.githubusercontent.com/MATPOWER/matpower/master/data/case118zh.m"
    
    try:
        req = urllib.request.urlopen(url)
        data = req.read().decode('utf-8')
    except Exception as e:
        print(f"Failed to download data: {e}")
        return
    
    # 1. Parse Bus Data
    bus_str = re.search(r'mpc\.bus\s*=\s*\[(.*?)\];', data, re.DOTALL).group(1)
    slack_bus = None
    all_buses = []
    
    for line in bus_str.split('\n'):
        line = line.split('%')[0].strip()
        line = line.replace(';', ' ')
        if not line: continue
        vals = [float(x) for x in line.split()]
        if not vals: continue
        
        bus_id = int(vals[0])
        all_buses.append(bus_id)
        if int(vals[1]) == 3:
            slack_bus = bus_id
            
    # 2. Parse Branch Data and CONVERT TO P.U.
    branch_str = re.search(r'mpc\.branch\s*=\s*\[(.*?)\];', data, re.DOTALL).group(1)
    branches = []
    
    for line in branch_str.split('\n'):
        line = line.split('%')[0].strip()
        line = line.replace(';', ' ') 
        if not line: continue
        vals = [float(x) for x in line.split()]
        if not vals: continue
        
        # Convert Ohms to PU right here
        r_pu_val = vals[2] / z_BASE
        x_pu_val = vals[3] / z_BASE
        
        branches.append({
            'from': int(vals[0]),
            'to': int(vals[1]),
            'r_pu': r_pu_val,
            'x_pu': x_pu_val
        })
        
    # 3. Construct A_Matrix and Vectors_PU
    num_branches = len(branches)
    non_slack_buses = sorted([b for b in all_buses if b != slack_bus])
    
    A_matrix = np.zeros((num_branches, len(non_slack_buses)), dtype=int)
    a_0 = np.zeros(num_branches, dtype=int)
    r_pu = np.zeros(num_branches)
    x_pu = np.zeros(num_branches)
    branch_names = [f"Branch_{i+1}" for i in range(num_branches)]
    
    for i, br in enumerate(branches):
        f_bus = br['from']
        t_bus = br['to']
        r_pu[i] = br['r_pu']
        x_pu[i] = br['x_pu']
        
        if f_bus == slack_bus:
            a_0[i] = 1
        elif t_bus == slack_bus:
            a_0[i] = -1
            
        if f_bus != slack_bus:
            col_idx = non_slack_buses.index(f_bus)
            A_matrix[i, col_idx] = 1
        if t_bus != slack_bus:
            col_idx = non_slack_buses.index(t_bus)
            A_matrix[i, col_idx] = -1

    # 4. Create DataFrames
    bus_col_names = [f"Bus_{b}" for b in non_slack_buses]
    
    df_A = pd.DataFrame(A_matrix, columns=bus_col_names, index=branch_names)
    df_A.index.name = "Unnamed: 0"
    
    df_vec = pd.DataFrame({
        'a_0': a_0,
        'r_pu': r_pu,
        'x_pu': x_pu
    }, index=branch_names)
    df_vec.index.name = "Unnamed: 0"
    
    # 5. Export to Excel
    output_filename = 'IEEE118zh_LinDistFlow_Matrices_PU.xlsx'
    
    with pd.ExcelWriter(output_filename) as writer:
        df_A.to_excel(writer, sheet_name='A_Matrix')
        df_vec.to_excel(writer, sheet_name='Vectors_PU')
        
    print(f"Success! Ohms converted to p.u. and saved to {output_filename}.")

def generate_69_bus_excel_pu():
    # ==========================================
    # IEEE 69-BUS BASE VALUES
    # ==========================================
    v_BASE_KV = 12.66   # Standard for 69-bus (Baran & Wu)
    s_BASE_MVA = 10.0   # Standard System Base
    z_BASE = (v_BASE_KV ** 2) / s_BASE_MVA
    # ==========================================
    print(f"System z_base: {z_BASE:.4f} Ohms")
    print("Fetching IEEE 69-bus data...")
    
    url = "https://raw.githubusercontent.com/MATPOWER/matpower/master/data/case69.m"
    
    try:
        req = urllib.request.urlopen(url)
        data = req.read().decode('utf-8')
    except Exception as e:
        print(f"Error downloading data: {e}")
        return

    # 1. Parse Bus Data
    bus_str = re.search(r'mpc\.bus\s*=\s*\[(.*?)\];', data, re.DOTALL).group(1)
    slack_bus = 1
    all_buses = []
    for line in bus_str.split('\n'):
        line = line.split('%')[0].strip().replace(';', ' ')
        if not line: continue
        vals = [float(x) for x in line.split()]
        if not vals: continue
        bus_id = int(vals[0])
        all_buses.append(bus_id)
        if int(vals[1]) == 3: slack_bus = bus_id
            
    # 2. Parse Branch Data and CONVERT Ohms -> PU
    branch_str = re.search(r'mpc\.branch\s*=\s*\[(.*?)\];', data, re.DOTALL).group(1)
    branches = []
    for line in branch_str.split('\n'):
        line = line.split('%')[0].strip().replace(';', ' ')
        if not line: continue
        vals = [float(x) for x in line.split()]
        if not vals: continue
        
        # Applying the conversion from Ohms to p.u.
        r_pu_val = vals[2] / z_BASE
        x_pu_val = vals[3] / z_BASE
        
        branches.append({
            'from': int(vals[0]),
            'to': int(vals[1]),
            'r_pu': r_pu_val,
            'x_pu': x_pu_val
        })
        
    # 3. Construct Matrices
    num_branches = len(branches)
    non_slack_buses = sorted([b for b in all_buses if b != slack_bus])
    
    A_matrix = np.zeros((num_branches, len(non_slack_buses)), dtype=int)
    a_0 = np.zeros(num_branches, dtype=int)
    r_pu_vec = np.zeros(num_branches)
    x_pu_vec = np.zeros(num_branches)
    branch_names = [f"Branch_{i+1}" for i in range(num_branches)]
    
    for i, br in enumerate(branches):
        f, t = br['from'], br['to']
        r_pu_vec[i], x_pu_vec[i] = br['r_pu'], br['x_pu']
        
        if f == slack_bus: a_0[i] = 1
        elif t == slack_bus: a_0[i] = -1
            
        if f != slack_bus:
            A_matrix[i, non_slack_buses.index(f)] = 1
        if t != slack_bus:
            A_matrix[i, non_slack_buses.index(t)] = -1

    # 4. Save to Excel
    output_filename = 'IEEE69_LinDistFlow_Matrices_PU.xlsx'
    df_A = pd.DataFrame(A_matrix, columns=[f"Bus_{b}" for b in non_slack_buses], index=branch_names)
    df_A.index.name = "Unnamed: 0"
    df_vec = pd.DataFrame({'a_0': a_0, 'r_pu': r_pu_vec, 'x_pu': x_pu_vec}, index=branch_names)
    df_vec.index.name = "Unnamed: 0"
    
    with pd.ExcelWriter(output_filename) as writer:
        df_A.to_excel(writer, sheet_name='A_Matrix')
        df_vec.to_excel(writer, sheet_name='Vectors_PU')
    
    print(f"Successfully converted and saved to {output_filename}")


# Run the extraction
# generate_118zh_excel_pu()
generate_69_bus_excel_pu()