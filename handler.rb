require 'json'
require 'bigdecimal'
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

  publish_rds_os_metrics(instance_id, events)
  publish_rds_cpu_metrics(instance_id, events)

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

# Publish total CPU metrics for guest, irq, system, 
# wait, idle, user, steal, nice, and total.
def publish_rds_cpu_metrics(instance_id, events)
  sums = {}
  minimums = {}
  maximums = {}
  event_count = 0

  events.events.each do |event|
    timestamp = Time.at(event.timestamp / 1000)
    data = JSON.parse(event.message)
    data['cpuUtilization'].each do |metric, value|
      dimension = [
        { name: "rds_instance", value: instance_id },
        { name: "metric", value: metric }
      ]
      sums[dimension] ||= 0
      sums[dimension] += value

      minimums[dimension] ||= BigDecimal('Infinity')
      if value.to_f < minimums[dimension]
        minimums[dimension] = value.to_f
      end

      maximums[dimension] ||= BigDecimal('-Infinity')
      if value.to_f > maximums[dimension]
        maximums[dimension] = value.to_f
      end
    end
    event_count += 1
  end

  cw = Aws::CloudWatch::Client.new
  sums.keys.each do |dimension|
    metric_name = dimension.last[:value]
    cw.put_metric_data({
      namespace: "RDS_CPU_Metrics",
      metric_data: [{
        metric_name: metric_name,
        timestamp: Time.now,
        unit: "Percent",
        statistic_values: {
          sample_count: event_count,
          sum: sums[dimension],
          minimum: minimums[dimension],
          maximum: maximums[dimension]
        },
        # divide by event count for average
        # NOTE: statistic_values and value are mutually exclusive
        #value: (sums[dimension].to_f / event_count.to_f),
        dimensions: dimension[0..-2]
      }]
    })
  end

end

# Publish per-process (categoried) CPU and memory 
# utilization
def publish_rds_os_metrics(instance_id, events)
  # Aggregation of all metrics for this time interval
  # [ dimensions ] => value
  sums = {}
  minimums = {}
  maximums = {}
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

      minimums[ dimension + [{name:"metric",value:"CPU"}] ] ||= BigDecimal('Infinity')
      if process['cpuUsedPc'].to_f < minimums[ dimension + [{name:"metric",value:"CPU"}] ]
        minimums[ dimension + [{name:"metric",value:"CPU"}] ] = process['cpuUsedPc'].to_f
      end

      maximums[ dimension + [{name:"metric",value:"CPU"}] ] ||= BigDecimal('-Infinity')
      if process['cpuUsedPc'].to_f > maximums[ dimension + [{name:"metric",value:"CPU"}] ]
        maximums[ dimension + [{name:"metric",value:"CPU"}] ] = process['cpuUsedPc'].to_f
      end

      sums[ dimension + [{name:"metric",value:"Memory"}] ] ||= 0
      sums[ dimension + [{name:"metric",value:"Memory"}] ] += process['memoryUsedPc'].to_f

      minimums[ dimension + [{name:"metric",value:"Memory"}] ] ||= BigDecimal('Infinity')
      if process['memoryUsedPc'].to_f < minimums[ dimension + [{name:"metric",value:"Memory"}] ]
        minimums[ dimension + [{name:"metric",value:"Memory"}] ] = process['memoryUsedPc'].to_f
      end

      maximums[ dimension + [{name:"metric",value:"Memory"}] ] ||= BigDecimal('-Infinity')
      if process['memoryUsedPc'].to_f > maximums[ dimension + [{name:"metric",value:"Memory"}] ]
        maximums[ dimension + [{name:"metric",value:"Memory"}] ] = process['memoryUsedPc'].to_f
      end

    end
    event_count += 1
  end

  # Iterate over the sums and publish average statistics
  # for this time interval
  cw = Aws::CloudWatch::Client.new
  sums.keys.each do |dimension|
    metric_name = dimension.last[:value]
    cw.put_metric_data({
      namespace: "RDS_OS_Metrics",
      metric_data: [{
        metric_name: metric_name,
        timestamp: Time.now,
        unit: "Percent",
        statistic_values: {
          sample_count: event_count,
          sum: sums[dimension],
          minimum: minimums[dimension],
          maximum: maximums[dimension]
        },
        # divide by event count for average
        # NOTE: statistic_values and value are mutually exclusive
        #value: (sums[dimension].to_f / event_count.to_f),
        dimensions: dimension[0..-2]
      }]
    })
  end

end
