require 'json'
require 'aws-sdk-rds'
require 'aws-sdk-cloudwatchlogs'
require 'aws-sdk-cloudwatch'
require 'chronic_duration'

# Event input JSON
# * instance_id:    Your database instance name
# * interval:       Human readable duration that this script runs.
#                   Aggregates stats over this time frame for publishing
#                   to CloudWatch metrics.  Default: "1 minute"

# Cache for multiple RDS instances in the same
# Lambda execution environment.  This saves
# one API call for looking up the resource ID.
@resource_ids = {}

def handler(event:, context:)
  $stdout.sync = true
  $stderr.sync = true

  @resource_ids ||= {}

  puts "event: #{event.inspect}"
  puts "resource id cache: #{@resource_ids.inspect}"

  interval = event['interval'] || "1 minute"
  instance_id = event['instance_id']

  rds = Aws::RDS::Client.new
  @resource_ids[instance_id] ||= rds.describe_db_instances({
    db_instance_identifier: instance_id
  }).to_h[:db_instances][0][:dbi_resource_id]

  cwl = Aws::CloudWatchLogs::Client.new
  events = cwl.get_log_events({
    log_group_name: "RDSOSMetrics",
    log_stream_name: @resource_ids[instance_id],
    start_time: (Time.now - ChronicDuration.parse(interval)).to_i * 1000
  })

  # Aggregation of all metrics for this time interval
  # [ dimensions ] => value
  sums = {}
  event_count = 0

  events.events.each do |event|
    timestamp = Time.at(event.timestamp / 1000)
    data = JSON.parse(event.message)
    data['processList'].each do |process|
      dimension = parse_process_dimension(instance_id, process['name'])
      # Other interesting metrics are available here, like vss and rss, but I'm more 
      # interested in just percentages
      sums[ dimension + [{name:"metric",value:"CPU"}] ] ||= 0 
      sums[ dimension + [{name:"metric",value:"CPU"}] ] += process['cpuUsedPc'].to_f
      #if process['cpuUsedPc'].to_f > sums[ dimension + [{name:"metric",value:"CPU"}] ].to_f
      #  sums[ dimension + [{name:"metric",value:"CPU"}] ] = process['cpuUsedPc'].to_f
      #end

      sums[ dimension + [{name:"metric",value:"Memory"}] ] ||= 0
      sums[ dimension + [{name:"metric",value:"Memory"}] ] += process['memoryUsedPc'].to_f
      #if process['memoryUsedPc'].to_f > sums[ dimension + [{name:"metric",value:"Memory"}] ]
      #  sums[ dimension + [{name:"metric",value:"Memory"}] ] = process['memoryUsedPc'].to_f
      #end
    end
    event_count += 1
  end

  # Iterate over the sums and publish average statistics
  # for this time interval
  cw = Aws::CloudWatch::Client.new
  sums.each do |dimension, value|
    metric_name = dimension.pop[:value]
    cw.put_metric_data({
      namespace: "RDS_OS_Metrics",
      metric_data: [{
        metric_name: metric_name,
        timestamp: Time.now,
        unit: "Percent",
        # divide by event count for average
        value: (value.to_f / event_count.to_f),
        # NOTE:  Do we want to use the max instead?
        #value: value.to_f,
        dimensions: dimension
      }]
    })
  end

rescue => e
  puts "Exception: #{e.message}"
  raise e
end

# Take a process name, categorize it and return the 
# dimensions of a CW metric for this PID
def parse_process_dimension(instance_id, name)
  dimension = [
    { name: "rds_instance", value: instance_id }
  ]
  case name
  when /^postgres: postgres/, "postgres"
    dimension.push({ name: "service", value: "postgres"})
  when /^postgres: rdsadmin/, /^postgres: aurora/
    dimension.push({ name: "service", value: "postgres-aurora"})
  when /^postgres: /, "pg_controldata"
    dimension.push({ name: "service", value: "postgres-background"})
  when "Aurora Storage Daemon"
    dimension.push({ name: "service", value: "aurora-storage"})
  when "RDS processes"
    dimension.push({ name: "service", value: "rds-processes"})
  when "OS processes"
    dimension.push({ name: "service", value: "os-processes"})
  else
    puts "Can't figure out what this process is: #{name}"
  end

  dimension
end
