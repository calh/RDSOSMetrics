# CloudWatch RDS OS Metrics

There are quite a few things going on under the hood of Aurora, some of which might be 
consuming extra resources without much explanation.

For each Aurora Postgres instance, there are `RDS processes`, `Aurora Storage Daemon`, 
`rsdadmin` background processes, aurora runtimes, and `OS processes`.  You can see 
a glimpse of them in the RDS dashboard, under Monitoring -> OS Process List.

After spending months tracking down unexplained CPU utilization, I discovered
that the RDS processes consumes a majority of the CPU when query logging
is enabled.  After several months of uptime, the CPU utilization increases
even more.

This Lambda script pulls metrics from the CloudWatch RDSOSMetrics logs,
parses the CPU and memory utilization for each PID, aggregates, categorizes
and then publishes custom CloudWatch metrics for a given RDS instance.

(Neat screenshot here)

While this was written for Aurora Postgres, it could be tailored for MySQL as well.  

### First Local Test

If you have Ruby installed, you can run a quick test without doing all of the deployment work below, try this out:

```
$ bundle install
# Edit runner.rb and change the `event` hash
$ export AWS_ACCESS_KEY_ID=...
$ export AWS_SECRET_ACCESS_KEY=...
$ export AWS_DEFAULT_REGION=...
$ bundle exec ruby runner.rb
```

Wait a few minutes, and then check out your [CloudWatch custom metrics](https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#metricsV2).

There should be an `RDS_OS_Metrics` custom namespace with everything fun in it.

### First Deployment

Install Docker for the CI build process

```
$ ./script/ci_build
$ ./script/create_function --profile me --region us-east-1 --name rdsosmetrics
```

### Create an EventBridge Rule

[Create a Rule](https://us-east-1.console.aws.amazon.com/events/home?region=us-east-1#/rules/create)

Given that your database instance name is called `prod-writer`:

* Name: `prod-writer_RDS_OS_Metrics`
* Description: `Publish RDS metrics to CloudWatch for prod-writer`
* Rule type: `Schedule`  (click Next)
* A schedule that runs at a regular rate: `1 minute`  (click Next)
* AWS Service -> Lambda function -> rdsosmetrics
* Additional settings -> Configure target input -> Constant (JSON text)
* Paste in parameters to call the function with:

```
{ 
  "instance_id": "prod-writer", 
  "interval": "1 minute"
}
```

* `instance_id`: The instance name of the RDS Aurora instance to publish metrics for
* `interval`:  Human readable duration that this script runs. Aggregates stats over this time frame for publishing to CloudWatch metrics.  Default: "1 minute"

* Set Maximum age to 1 minute, retry attempts to 0.  If the script fails, you don't want re-runs to build up.

Create a new rule for each Aurora instance you want to monitor.

### Create a CloudWatch Widget

Use this as a JSON source.  I'm interested in RDS Processes and regular Postgres user CPU activity.
Everything else I group into an Other category.

```
{
  "metrics": [
    [ "RDS_OS_Metrics", "CPU", "service", "postgres", "rds_instance", "prod-writer", { "id": "m1" } ],
    [ "...", "rds-processes", ".", ".", { "id": "m2" } ],
    [ "...", "postgres-aurora", ".", ".", { "id": "m3", "visible": false } ],
    [ "...", "aurora-storage", ".", ".", { "id": "m4", "visible": false } ],
    [ "...", "postgres-background", ".", ".", { "id": "m5", "visible": false } ],
    [ "...", "os-processes", ".", ".", { "id": "m6", "visible": false } ],
    [ { "expression": "m3 + m4 + m5 + m6", "label": "Other", "id": "e1" } ]
  ],
  "view": "timeSeries",
  "stacked": false,
  "region": "us-east-1",
  "stat": "Average",
  "period": 60
}
```

And one for memory, although this isn't as interesting:


```
{
  "metrics": [
    [ "RDS_OS_Metrics", "Memory", "service", "postgres", "rds_instance", "prod-writer", { "id": "m1" } ],
    [ "...", "rds-processes", ".", ".", { "id": "m2" } ],
    [ "...", "postgres-aurora", ".", ".", { "id": "m3", "visible": false } ],
    [ "...", "aurora-storage", ".", ".", { "id": "m4", "visible": false } ],
    [ "...", "postgres-background", ".", ".", { "id": "m5", "visible": false } ],
    [ "...", "os-processes", ".", ".", { "id": "m6", "visible": false } ],
    [ { "expression": "m3 + m4 + m5 + m6", "label": "Other", "id": "e1" } ]
  ],
  "view": "timeSeries",
  "stacked": false,
  "region": "us-east-1",
  "stat": "Average",
  "period": 60
}
```

### Updating New Code

```
$ ./script/ci_build
$ ./script/update_function --profile me --region us-east-1 --name rdsosmetrics
```


