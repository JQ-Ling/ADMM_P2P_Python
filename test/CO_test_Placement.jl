# ====================================================================
# SANITY TEST SCRIPT
# Run via terminal: julia --project=. sanity_test.jl
# ====================================================================

# 1. Include and load your module
println("Loading Module...")
include("../subproblems/CO_Placement.jl") 
using .Centralized_CES_Model

function run_test(bus_sys, ces_config)
    # 3. Run the setup_data function (caches data into DATA Dict)
    println("\n=== 1. Testing setup_data() ===")
    @time Centralized_CES_Model.setup_data(bus_sys)

    # 4. Define dummy test parameters for the CES units
    # Ensure they are Float64 vectors as expected by evaluate_fitness
    # Example: 2 CES units -> 50kW at Bus 15, and 100kW at Bus 45.
    to_vector(x) = x isa AbstractVector ? Vector{Float64}(x) : Float64[x]
    
    ces_sizes = to_vector(ces_config["ces_sizes"])
    ces_locs  = to_vector(ces_config["ces_locs"])

    # 5. Run the optimization function
    println("\n=== 2. Testing evaluate_fitness() ===")
    println("Inputs -> Sizes: ", ces_sizes, " | Locations: ", ces_locs)
    
    # We use @time to see exactly how long Gurobi takes to build and solve
    @time results = Centralized_CES_Model.evaluate_fitness(ces_sizes, ces_locs)

    # 6. Display Output gracefully
    println("\n=== 3. Optimization Results ===")
    if results["infeasible"] == 0
        println("Status:        SUCCESS (OPTIMAL)")
        
        # In CO_Placement.jl, pros_cost might be a vector of 68 users. 
        # We sum it to get the total system cost.
        total_cost = sum(results["cost"])
        
        println("Total Cost:    ", round(total_cost, digits=4))
        println("Total Profit:  ", round(results["profit"], digits=4))
        println("CES Matrix:    ", results["CES_shape"][1], " hours x ", results["CES_shape"][2], " buses")
    else
        println("Status:        FAILED (INFEASIBLE)")
        println("Check if the sizes are too large for the branch limits.")
    end
end

# Execute the test
bus_sys = 69
ces_locs = 2
ces_sizes = 7.425284391
ces_config = Dict("ces_sizes" => ces_sizes, "ces_locs" => ces_locs)
run_test(bus_sys, ces_config)