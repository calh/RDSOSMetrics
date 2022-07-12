# Simple test script
# Remember to set your AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY!

# Set this to your db instance name
event = {
  "instance_id" => ARGV[0]
}

require "./handler.rb"

# Simulate what this will behave like when run with
# a cached execution environment in Lambda
loop do 
  start = Time.now
  handler(event:event,context:{})
  puts "execution time: #{ (Time.now - start) * 1000 }"
  sleep 60
end
