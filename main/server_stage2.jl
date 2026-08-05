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

# Same idea, but for a comma-separated list of numbers (e.g. "500, 500")
function ask_numbers(question, default::Vector{Float64})
    while true
        print(question)
        flush(stdout)
        reply = strip(readline())
        isempty(reply) && return default
        parsed = tryparse.(Float64, strip.(split(reply, ',')))
        if !any(isnothing, parsed) && !isempty(parsed)
            return Vector{Float64}(parsed)
        end
        println("[Warning] Could not read \"$reply\". Enter numbers separated by commas, e.g. 500, 500")
    end
end

println("=========================================")

# 2. Ask for the Stage / Data / Module Choice
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
    module_used = "CO_ROI_stage2.jl"
end

is_stage2 = stage_choice == "2"
week_ahead = data_choice == "2"

# 3. Ask for the Bus system Choice
bus_choice = ask("Select bus system (33 / 69) [default 33]: ", ["33", "69"], "33")
bus_sys = parse(Int, bus_choice)
# Temporary: the 7-day data set only exists for the 33-bus system, and both
# CO_ROI_stage1.jl and CO_ROI_stage2.jl assert on it.
if week_ahead && bus_sys != 33
    println("[Warning] Week-ahead data is only available for 33-bus systems. Using 33-bus system.")
    bus_sys = 33
end

# 4. Stage 2 optimises the price scheme on a FIXED CES fleet, so the fleet has
#    to be pinned at startup instead of arriving with each request.
function ask_fleet()
    while true
        sizes = ask_numbers("CES sizes in kWh, comma separated [default 500, 500]: ", [500.0, 500.0])
        locs  = ask_numbers("CES bus locations, comma separated [default 10, 25]: ", [10.0, 25.0])
        length(sizes) == length(locs) && return sizes, locs
        println("[Warning] Got $(length(sizes)) size(s) but $(length(locs)) location(s) - they must match.")
    end
end

if is_stage2
    ces_sizes, ces_locs = ask_fleet()
end

println("=========================================")
println("Stage Choice       : ", stage_choice, " -> ", is_stage2 ? "Opt Price Scheme" : "Opt Placement")
println("Input Data         : ", week_ahead ? "Week-ahead" : "Day-ahead")
println("Module Used        : ", module_used)
println("Bus System Choice  : ", bus_sys)
is_stage2 && println("Fixed CES Fleet    : sizes = ", ces_sizes, " at buses ", Int.(round.(ces_locs)))

include("../subproblems/" * module_used)
using .Centralized_CES_Model

# Initialize the chosen bus data once at startup
if is_stage2
    Centralized_CES_Model.setup_data(bus_sys; ces_sizes = ces_sizes, ces_locs = ces_locs)
else
    Centralized_CES_Model.setup_data(bus_sys)
end

# Define the "Endpoint" that MATLAB will call
@post "/evaluate" function(req::HTTP.Request)
    data = JSON3.read(req.body)

    # Use wrap_array logic to handle both single values and arrays
    to_vector(x) = x isa AbstractVector ? Vector{Float64}(x) : [Float64(x)]

    # Run optimization
    if is_stage2
        # Stage 2 particle = the price scheme. The CES fleet is already fixed.
        #   {"scenario":"subscription", "priority":0.005, "sub_caps":[...]}
        #   {"scenario":"usage", "cost_array":[c_nrm,d_nrm,c_p2p,d_p2p,c_cls,d_cls]}
        scenario = Symbol(data.scenario)
        results = if scenario == :subscription
            Centralized_CES_Model.evaluate_fitness(:subscription,
                                                   Float64(data.priority),
                                                   to_vector(data.sub_caps))
        elseif scenario == :usage
            Centralized_CES_Model.evaluate_fitness(:usage, to_vector(data.cost_array))
        else
            return HTTP.Response(400, "Unknown scenario \"$(data.scenario)\" - expected \"subscription\" or \"usage\".")
        end
    else
        # Stage 1 particle = the CES fleet itself
        #   {"ces_sizes":[...], "ces_locs":[...]}
        sizes = to_vector(data.ces_sizes)
        locs  = to_vector(data.ces_locs)
        results = Centralized_CES_Model.evaluate_fitness(sizes, locs)
    end

    GC.gc()

    # Send results back as JSON
    return results
end

println("Server Port        : http://127.0.0.1:$port_num")
println("=========================================")
serve(port=port_num)
