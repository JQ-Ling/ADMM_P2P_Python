# Run this once in Julia: using Pkg; Pkg.add(["Oxygen", "HTTP", "JSON3"])
using Oxygen, HTTP, JSON3
include("../subproblems/CO_Placement.jl")
using .Centralized_CES_Model

# Initialize the 69-bus data once at startup
bus_sys = 69
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

println("Julia Optimization Server running at http://127.0.0.1:8080")
serve(port=8080)