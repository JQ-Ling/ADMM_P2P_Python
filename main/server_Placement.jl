using Oxygen, HTTP, JSON3

# 1. Parse Port (Argument 1) - Defaults to 8080 if not provided
port_num = length(ARGS) > 0 ? parse(Int, ARGS[1]) : 8080

# 2. Parse Module Choice (Argument 2) - Defaults to "1" if not provided
module_choice = length(ARGS) > 1 ? ARGS[2] : "1"

if module_choice == "1"
    module_used = "CO_Placement.jl"
elseif module_choice == "2"
    module_used = "CO_Placement_ptdf.jl"
else
    println("\n[Warning] Invalid module choice. Defaulting to 1: CO_Placement.jl")
    module_used = "CO_Placement.jl"
end

# 3. Parse Bus system Choice (Argument 3) - Defaults to 33 (33 bus) if not provided
valid_bus_systems = [33, 69]
bus_sys = length(ARGS) > 2 ? parse(Int, ARGS[3]) : 33

if !(bus_sys in valid_bus_systems)
    println("\n[Warning] Invalid bus system choice. Defaulting to 33 bus system.")
    bus_sys = 33
end

println("=========================================")
println("Module Choice      : ", module_choice, " -> Using: ", module_used)
println("Bus System Choice  : ", bus_sys)
include("../subproblems/" * module_used)
using .Centralized_CES_Model

# Initialize the chosen bus data once at startup
Centralized_CES_Model.setup_data(bus_sys)

# Define the "Endpoint" that MATLAB will call
@post "/evaluate" function(req::HTTP.Request)
    data = JSON3.read(req.body)
    
    # Use wrap_array logic to handle both single values and arrays
    to_vector(x) = x isa AbstractVector ? Vector{Float64}(x) : [Float64(x)]
    
    sizes = to_vector(data.ces_sizes)
    locs  = to_vector(data.ces_locs)
    
    # Run optimization
    results = Centralized_CES_Model.evaluate_fitness(sizes, locs)
    
    GC.gc() 
    
    # Send results back as JSON
    return results
end

println("Server Port        : http://127.0.0.1:$port_num")
println("=========================================")
serve(port=port_num)