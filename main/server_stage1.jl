using Oxygen, HTTP, JSON3

# 1. Parse Port (Argument 1) - Defaults to 8080 if not provided
port_num = length(ARGS) > 0 ? parse(Int, ARGS[1]) : 8080

# Ask until the answer is valid. A blank line (or a closed stdin, e.g. when the
# server is started non-interactively) accepts the default.
function ask(question, valid_choices, default)
    while true
        print(question)
        flush(stdout)
        reply = strip(readline())
        isempty(reply) && return default
        reply in valid_choices && return reply
        println("[Warning] Invalid choice \"$reply\". Valid options: ", join(valid_choices, ", "))
    end
end

println("=========================================")

# 2. Ask for the Module Choice
stage_choice = ask("""
Select Stage option:
  1) Stage 1 (Opt Placement)
  2) Stage 2 (Opt Price Scheme)
Choice [default 1]: """, ["1", "2"], "1")

if stage_choice == "1"
    data_choice = ask("""
    Select Input Data:
    1) Day-ahead
    2) Week-ahead
    Choice [default 1]: """, ["1", "2"], "1")
    
    if data_choice == "1"
        module_choice = ask("""
        Select Module:
        1) CO_Placement_LDF.jl
        2) CO_Placement_ptdf.jl
        Choice [default 1]: """, ["1", "2"], "1")

        module_used = module_choice == "1" ? "CO_Placement_LDF.jl" : "CO_Placement_ptdf.jl"
    else
        module_used = "CO_ROI_stage1.jl"
    end
else
    # Stage 2 is only compatible with week-ahead data
    println("Stage 2 (Opt Price Scheme) is only compatible with week-ahead data. Using week-ahead data.")
    data_choice = "2"
    module_used = "CO_ROI_stage1.jl"
end

# 3. Ask for the Bus system Choice
bus_choice = ask("Select bus system (33 / 69) [default 33]: ", ["33", "69"], "33")
bus_sys = parse(Int, bus_choice)
# Temporary
if stage_choice == "2" && bus_sys != 33
    println("[Warning] Stage 2 is only compatible with 33-bus systems. Using 33-bus system.")
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