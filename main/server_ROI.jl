# Run once: using Pkg; Pkg.add(["Oxygen", "HTTP", "JSON3"])
using Oxygen, HTTP, JSON3
include("../subproblems/CO_ROI.jl")
using .Centralized_CES_Model

# Initialize the 69-bus data once at startup
bus_sys = 33
Centralized_CES_Model.setup_data(bus_sys)

@post "/evaluate" function(req::HTTP.Request)
    # Parse the incoming JSON data from MATLAB
    data = JSON3.read(req.body)
    
    # ---------------------------------------------------------
    # FIX 1: The "Vector{Float64}" Error
    # If MOMSA only places 1 CES unit, JSON sends a single Float.
    # This safely wraps single numbers into an array.
    # ---------------------------------------------------------
    to_vector(x) = x isa AbstractVector ? Vector{Float64}(x) : [Float64(x)]
    
    sizes = to_vector(data.ces_sizes)
    locs  = to_vector(data.ces_locs)
    
    # Run the Gurobi optimization
    results = Centralized_CES_Model.evaluate_fitness(sizes, locs)
    
    # ---------------------------------------------------------
    # FIX 2: The RAM Memory Leak 
    # Forces Julia to delete the temporary JSON text, matrices, 
    # and C++ Gurobi environment pointers before responding.
    # ---------------------------------------------------------
    GC.gc() 
    
    return results
end

println("Julia Optimization Server running at http://127.0.0.1:8080")
serve(port=8080)