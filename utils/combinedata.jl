using CSV, DataFrames, JSON

dataset = "D:\\Jacky\\Data Output\\ADMM_P2P\\Database\\Train\\LP_PrioGO-LDF-mulCES-4dec_train_InterGen_1000sce"

config_path = "$(dataset)/config.json"
config = JSON.parsefile(config_path)

hour = 48
num_user = 32
data_size = config["sce_end"] - config["sce_start"] + 1
num_dec = config["number of decisions"]
iter_save = config["iter_save"] + 1

all_dual = []
all_primal = []
all_pdec = []
all_infeasible = []

#declare the range of scenarios you wish to save in 1 file
start_sce_save = config["sce_start"]
i = start_sce_save
end_sce_save = config["sce_end"]

############################# read all infeasible scenario index#############
data_directory = "$(dataset)/infeasible_sce/"
pattern = "infeasible_sce_*to*sce.csv"
infeasible_files = readdir(data_directory)
# infeasible_files = [file for file in infeasible_dir if startswith(file, pattern)]

for file in infeasible_files
    println(file)

    # Construct the full path to the CSV file
    full_path = joinpath(data_directory, file)

    # Read the CSV file into a DataFrame
    df = CSV.read(full_path, DataFrame) 

    infeasible_mat = Matrix(df)

    #store all the infeasible scenario index
    for inf_sce in infeasible_mat
        push!(all_infeasible, inf_sce)
    end
end

all_infeasible = sort(unique(all_infeasible))
#############################################################################3


#read csv files
while i <=end_sce_save-4
    println("Processing scenarios from $(i) to $(i+4)")
    global all_dual, all_primal,i, end_sce_save, all_pdec
    first = i
    last = i+4
    if first < 10
        first = "0$(first)"
    end
    if last < 10
        last = "0$(last)"
    end
    # df_dv = CSV.read("$(dataset)/DecisionVariable/dual_$(first)to$(last)sce.csv", DataFrame)
    # df_pv = CSV.read("$(dataset)/DecisionVariable/primal_$(first)to$(last)sce.csv", DataFrame)
    df_pd = CSV.read("$(dataset)/DecisionVariable/P_decision_$(first)to$(last)sce.csv", DataFrame)

    # df_dv = Matrix(df_dv)
    # df_dv = reshape(df_dv, 5, num_dec * 48, 32, iter_save)

    # df_pv = Matrix(df_pv)
    # df_pv = reshape(df_pv, 5, num_dec * 48, 32, iter_save)

    df_pd = Matrix(df_pd)
    df_pd = reshape(df_pd, 5, 8 * 48, 32, iter_save)

    #combine all arrays along the first dimension
    if i ==start_sce_save
        # all_dual =df_dv
        # all_primal =df_pv
        all_pdec = df_pd
    else
        # all_dual = cat(all_dual, df_dv, dims=1)
        # all_primal = cat(all_primal, df_pv, dims=1)
        all_pdec = cat(all_pdec, df_pd, dims=1)
    end

    i+=5
end


#check if you first sce of saving starts from the middle of the dataset
if start_sce_save != 1
    all_infeasible = all_infeasible .- (start_sce_save-1)
end

#remove infeasible indices
# Create a new array excluding the specified indices
# remaining_indices_d = setdiff(1:size(all_dual, 1), all_infeasible)
# remaining_indices_p = setdiff(1:size(all_primal, 1), all_infeasible)
remaining_indices_pd = setdiff(1:size(all_pdec, 1), all_infeasible)

# Remove the specified indices along the first dimension
# all_dual = all_dual[remaining_indices_d, :, :, :]
# all_primal = all_primal[remaining_indices_p, :, :, :]
all_pdec = all_pdec[remaining_indices_pd, :, :, :]

#save to 1 csv
# all_dual = reshape(all_dual,:,size(all_dual,4))
# all_primal = reshape(all_primal,:,size(all_primal,4))
all_pdec = reshape(all_pdec,:,size(all_pdec,4))

# all_dual = DataFrame(all_dual, :auto)
# all_primal = DataFrame(all_primal, :auto)
all_pdec = DataFrame(all_pdec, :auto)

# CSV.write("$(dataset)/training ready/dual_$(start_sce_save)to$(end_sce_save)testsce.csv",all_dual)
# CSV.write("$(dataset)/training ready/primal_$(start_sce_save)to$(end_sce_save)testsce.csv",all_primal)
CSV.write("$(dataset)/training ready/P_decision_$(start_sce_save)to$(end_sce_save)testsce.csv",all_pdec)

println("Total feasible scenario = $(data_size) - $(size(all_infeasible)[1]) = $(data_size-size(all_infeasible)[1])")
