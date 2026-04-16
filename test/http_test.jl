using StatsBase # Required for sample()

# =====================================================================
# 1. THE FUNCTION (Fully updated with the limit-tracking logic)
# =====================================================================
function generate_active_user(history_combinations, ledger_for_export, nb_prosumer, _num_user_active, sce, loc_prosumer)
    
    # Calculate mathematical maximum
    max_possible_combinations = binomial(nb_prosumer, _num_user_active)
    
    # Count how many we already have of this specific length
    current_count_for_size = count(comb -> length(comb) == _num_user_active, history_combinations)

    _rand_user_active = Int[]

    if current_count_for_size >= max_possible_combinations
        # Limit reached! Bypass the while loop to prevent freezing.
        println("  [Bypass Triggered] Limit of $max_possible_combinations reached. Allowing random repeat.")
        _rand_user_active = sample(1:nb_prosumer, _num_user_active, replace=false)
    else
        # Limit not reached. Force unique combination.
        println("  [Searching] Looking for unique combination... ($current_count_for_size / $max_possible_combinations found)")
        while true
            _rand_user_active = sample(1:nb_prosumer, _num_user_active, replace=false)
            fingerprint = Tuple(sort(_rand_user_active))
            
            if !(fingerprint in history_combinations)
                push!(history_combinations, fingerprint) 
                break 
            end
        end
    end
    
    # Map to grid (Dummy map for testing)
    # loc_prosumer[CartesianIndex.(_rand_user_active, _rand_user_active .+ 1)] .= 1

    # Save to ledger
    push!(ledger_for_export, Dict(
        "scenario" => sce,
        "num_users" => length(_rand_user_active),
        "active_users" => sort(_rand_user_active),
    ))

    return loc_prosumer, _rand_user_active, history_combinations, ledger_for_export
end

# =====================================================================
# 2. THE TEST ENVIRONMENT
# =====================================================================
println("Starting Test...")

# Dummy Variables
nb_prosumer = 5             # Tiny grid so we hit the limit fast
_num_user_active = 3        # 5 choose 4 means only 5 unique combinations exist!
loc_prosumer = zeros(5, 5)  # Dummy grid
history_combinations = Set{Tuple}() # Using Set for lightning-fast lookups!
ledger_for_export = []

# Run 8 Scenarios (It should find 5 unique, then repeat 3 times safely)
for sce in 1:20
    println("\n--- Running Scenario $sce ---")
    if sce in [3, 10]
        _num_user_active = 5  # Change to 5 active users to test the limit even more
    elseif sce in [6, 9, 1, 15, 18, 20]
        _num_user_active = 4  # Change to 3 active users to test a different limit
    else
        _num_user_active = 3
    end
    global loc_prosumer, _rand_user_active, history_combinations, ledger_for_export = generate_active_user(
        history_combinations, 
        ledger_for_export, 
        nb_prosumer, 
        _num_user_active, 
        sce, 
        loc_prosumer
    )
    println("  Resulting Active Users: ", sort(_rand_user_active))
end

println("\nTest Complete! It didn't freeze!")