using HTTP

function send_notification(message)
    # Use the same unique topic name you chose in the app
    topic = "julia-testing" 
    url = "https://ntfy.sh/$topic"
    
    try
        HTTP.post(url, body=message)
        println("Notification sent!")
    catch e
        println("Failed to send notification: $e")
    end
end

# --- YOUR BENCHMARK CODE START ---
println("Running heavy ML benchmarks...")
sleep(5) # Simulating your code
exe_time = 0.254
# --- YOUR BENCHMARK CODE END ---

# Send the results to your phone
msg = "Benchmark Complete! Time: $exe_time seconds. Excel file saved."
send_notification(msg)